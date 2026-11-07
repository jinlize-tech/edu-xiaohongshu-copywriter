param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$TestedTreeSha
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$meta = Get-Content -LiteralPath (Join-Path $repo 'product_meta.json') -Raw | ConvertFrom-Json
$version = $meta.version
$layers = [ordered]@{
    T1_FILE_STRUCTURE = [System.Collections.Generic.List[object]]::new()
    T2_METADATA_CONTRACT = [System.Collections.Generic.List[object]]::new()
    T3_PRODUCT_CONTRACT = [System.Collections.Generic.List[object]]::new()
    T4_DETERMINISTIC_FUNCTION = [System.Collections.Generic.List[object]]::new()
    T5_SCENARIO_TESTS = [System.Collections.Generic.List[object]]::new()
    T6_SECURITY = [System.Collections.Generic.List[object]]::new()
    T7_PACKAGE_INTEGRITY = [System.Collections.Generic.List[object]]::new()
}
$errors = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param(
        [string]$Layer,
        [string]$Name,
        [bool]$Passed,
        [string]$Expected,
        [string]$Actual,
        [string]$InputDescription,
        [string]$Execution
    )
    $layers[$Layer].Add([pscustomobject]@{
        name = $Name
        input = if ($InputDescription) { $InputDescription } else { $Name }
        execution = if ($Execution) { $Execution } else { 'PowerShell static or contract assertion in tests/validate_package.ps1' }
        expected = $Expected
        actual = $Actual
        passed = $Passed
    })
    if (-not $Passed) {
        $errors.Add("$Layer/$Name expected=$Expected actual=$Actual")
    }
}

function Get-NormalizedText {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n"
}

function Get-NormalizedTextSha256 {
    param([string]$Path)
    $text = Get-NormalizedText $Path
    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.UTF8Encoding]::new($false).GetBytes($text))
    ).Replace('-','')
}

function Test-JsonSubset {
    param($Expected, $Actual)
    if ($null -eq $Expected) { return $null -eq $Actual }
    if ($Expected -is [System.Collections.IList]) {
        $expectedItems = @($Expected)
        $actualItems = @($Actual)
        if ($expectedItems.Count -ne $actualItems.Count) { return $false }
        for ($i = 0; $i -lt $expectedItems.Count; $i++) {
            if (-not (Test-JsonSubset $expectedItems[$i] $actualItems[$i])) { return $false }
        }
        return $true
    }
    if ($Expected -is [pscustomobject]) {
        if ($null -eq $Actual) { return $false }
        foreach ($property in $Expected.PSObject.Properties) {
            if (-not $Actual.PSObject.Properties.Name.Contains($property.Name)) { return $false }
            if (-not (Test-JsonSubset $property.Value $Actual.($property.Name))) { return $false }
        }
        return $true
    }
    return $Expected -eq $Actual
}

function Invoke-NodeJson {
    param(
        [string]$ScriptPath,
        [string]$InputPath
    )
    $output = (& node $ScriptPath $InputPath 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    $json = $null
    try {
        $json = $output | ConvertFrom-Json
    }
    catch {
        $json = [pscustomobject]@{ status = 'INVALID_JSON_OUTPUT'; raw_output = $output }
    }
    return [pscustomobject]@{
        exit_code = $exitCode
        json = $json
        raw_output = $output
    }
}

$requiredCommon = @(
    'README.md',
    'PRODUCT_SPEC.md',
    'LICENSE',
    'BASELINE_VERSION.md',
    'USAGE.md',
    'CHANGELOG.md',
    'VERSION',
    'THIRD_PARTY_NOTICES.md',
    'product_meta.json',
    'package-manifest.json',
    'G5_G9_CHANGE_RECORD.md',
    $meta.package_path,
    'tests/TEST_CASES.md',
    'tests/validate_package.ps1',
    'tests/scenarios/complete.json',
    'tests/scenarios/missing.json',
    'tests/scenarios/conflict.json',
    'tests/scenarios/sensitive.json',
    'tests/scenarios/malformed.txt',
    'scripts/validate_input.js'
)
if ($meta.product_type -eq 'Skill') {
    $requiredCommon += @('SKILL.md','references/DOMAIN_GUIDE.md','references/EXAMPLES.md','templates/OUTPUT_TEMPLATE.md')
}
else {
    $requiredCommon += @(
        '.codebuddy-plugin/plugin.json',
        "agents/$($meta.repository_name).md",
        'avatars/expert.png',
        'PACKAGE_README.md',
        "skills/$($meta.repository_name)-core/SKILL.md",
        "skills/$($meta.repository_name)-core/scripts/validate_input.js",
        "skills/$($meta.repository_name)-core/templates/OUTPUT_TEMPLATE.md"
    )
}
if ($meta.calculator) {
    $requiredCommon += @('scripts/calculate.js','tests/calculator-cases.json','tests/calculator-cases')
}

foreach ($relative in $requiredCommon) {
    $path = Join-Path $repo $relative
    Add-Check 'T1_FILE_STRUCTURE' "exists:$relative" (Test-Path -LiteralPath $path) 'exists' $(if (Test-Path -LiteralPath $path) { 'exists' } else { 'missing' })
}

# T2 metadata contract
$versionText = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim()
Add-Check 'T2_METADATA_CONTRACT' 'version' ($versionText -eq $version) $version $versionText
Add-Check 'T2_METADATA_CONTRACT' 'status' ($meta.status -eq 'G9_PRE_RELEASE_ACCEPTED') 'G9_PRE_RELEASE_ACCEPTED' $meta.status
Add-Check 'T2_METADATA_CONTRACT' 'g5_status' ($meta.g5_status -eq 'G5_STRENGTHENED') 'G5_STRENGTHENED' $meta.g5_status
Add-Check 'T2_METADATA_CONTRACT' 'runtime_status' ($meta.runtime_status -eq 'NOT_RUNTIME_VERIFIED') 'NOT_RUNTIME_VERIFIED' $meta.runtime_status
Add-Check 'T2_METADATA_CONTRACT' 'workbuddy_status' ($meta.workbuddy_validation -eq 'WORKBUDDY_VALIDATION_NOT_IN_SCOPE') 'WORKBUDDY_VALIDATION_NOT_IN_SCOPE' $meta.workbuddy_validation
Add-Check 'T2_METADATA_CONTRACT' 'package_state' ($meta.package_state -eq 'GITHUB_PACKAGE_PRE_RELEASE_READY') 'GITHUB_PACKAGE_PRE_RELEASE_READY' $meta.package_state
Add-Check 'T2_METADATA_CONTRACT' 'baseline_commit' ($meta.baseline_commit -match '^[0-9a-f]{40}$') '40-char commit SHA' $meta.baseline_commit
Add-Check 'T2_METADATA_CONTRACT' 'main_output_fields' (@($meta.main_output_fields).Count -gt 0) 'at least one output field' @($meta.main_output_fields).Count

if ($meta.product_type -eq 'Skill') {
    $skill = Get-NormalizedText (Join-Path $repo 'SKILL.md')
    Add-Check 'T2_METADATA_CONTRACT' 'skill_name' ($skill -match "(?m)^name:\s*$([regex]::Escape($meta.repository_name))$") $meta.repository_name 'frontmatter'
    Add-Check 'T2_METADATA_CONTRACT' 'skill_version' ($skill -match "(?m)^version:\s*$([regex]::Escape($version))$") $version 'frontmatter'
    foreach ($key in @('display_name','display_name_en','description','description_zh','description_en','examples_zh','examples_en','author')) {
        Add-Check 'T2_METADATA_CONTRACT' "skill_field:$key" ($skill -match "(?m)^$([regex]::Escape($key)):\s*") 'present' 'checked'
    }
}
else {
    $pluginPath = Join-Path $repo '.codebuddy-plugin\plugin.json'
    $plugin = Get-Content -LiteralPath $pluginPath -Raw | ConvertFrom-Json
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_name' ($plugin.name -eq $meta.repository_name -and $plugin.agentName -eq $meta.repository_name) $meta.repository_name $plugin.name
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_version' ($plugin.version -eq $version) $version $plugin.version
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_category' ($plugin.categoryId -eq '15-Education') '15-Education' $plugin.categoryId
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_tags' (@($plugin.tags).Count -eq 3) '3' @($plugin.tags).Count
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_prompts' (@($plugin.quickPrompts).Count -eq 3) '3' @($plugin.quickPrompts).Count
    $descriptionLength = ($plugin.displayDescription.zh.ToCharArray()).Length
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_description_length' ($descriptionLength -ge 40 -and $descriptionLength -le 50) '40-50' $descriptionLength
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_default_prompt' ($plugin.defaultInitPrompt.zh -eq $plugin.quickPrompts[0].zh) 'match first quick prompt' 'checked'
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_license' ($plugin.license -eq 'Apache-2.0') 'Apache-2.0' $plugin.license
    $agent = Get-NormalizedText (Join-Path $repo "agents\$($meta.repository_name).md")
    Add-Check 'T2_METADATA_CONTRACT' 'agent_name' ($agent -match "(?m)^name:\s*$([regex]::Escape($meta.repository_name))$") $meta.repository_name 'frontmatter'
    Add-Check 'T2_METADATA_CONTRACT' 'agent_max_turns' ($agent -match '(?m)^maxTurns:\s*50$') '50' 'checked'
    $avatar = Get-Item -LiteralPath (Join-Path $repo 'avatars\expert.png')
    $image = [System.Drawing.Image]::FromFile($avatar.FullName)
    try {
        Add-Check 'T2_METADATA_CONTRACT' 'avatar_size' ($avatar.Length -le 512000) '<=512000' $avatar.Length
        Add-Check 'T2_METADATA_CONTRACT' 'avatar_dimensions' ($image.Width -eq 512 -and $image.Height -eq 512) '512x512' "$($image.Width)x$($image.Height)"
    }
    finally { $image.Dispose() }
}

# T3 product contract
$primaryTextPath = if ($meta.product_type -eq 'Skill') { Join-Path $repo 'SKILL.md' } else { Join-Path $repo "agents\$($meta.repository_name).md" }
$primary = Get-NormalizedText $primaryTextPath
$domainGuide = Get-NormalizedText (Join-Path $repo 'templates\OUTPUT_TEMPLATE.md')
Add-Check 'T3_PRODUCT_CONTRACT' 'workflow' ($primary.Contains('执行流程') -or $primary.Contains('多步骤执行')) 'workflow section' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'product_specific_rules' ($primary.Contains('产品专属') -and $primary.Contains('去重边界')) 'product-specific rules and dedup boundary' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'traceability_matrix' ($primary.Contains('核对矩阵') -or $primary.Contains('映射')) 'input-to-output mapping' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'input_contract' ($primary.Contains($meta.core_input)) $meta.core_input 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'output_contract' ($primary.Contains($meta.main_output) -or $domainGuide.Contains($meta.main_output)) $meta.main_output 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'exception_boundary' ($primary.Contains('异常') -and $primary.Contains('拒绝')) 'exception and refusal' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'independence' ($primary.Contains('无需安装其他教育产品') -or $primary.Contains('不依赖其他产品')) 'independent use' 'checked'
foreach ($outputField in @($meta.main_output_fields)) {
    Add-Check 'T3_PRODUCT_CONTRACT' "output_field:$outputField" ($domainGuide.Contains($outputField)) 'present in template' 'checked'
}

# T4 deterministic function
$inputValidator = Join-Path $repo 'scripts\validate_input.js'
$completePath = Join-Path $repo 'tests\scenarios\complete.json'
$complete = Invoke-NodeJson $inputValidator $completePath
Add-Check 'T4_DETERMINISTIC_FUNCTION' 'input_validator_complete' ($complete.exit_code -eq 0 -and $complete.json.validation_status -eq 'READY_FOR_PROCESSING') 'exit=0 status=READY_FOR_PROCESSING' "exit=$($complete.exit_code) status=$($complete.json.validation_status)" "tests/scenarios/complete.json" "node scripts/validate_input.js tests/scenarios/complete.json"
Add-Check 'T4_DETERMINISTIC_FUNCTION' 'output_contract_returned' (@($complete.json.output_fields).Count -eq @($meta.main_output_fields).Count) "$(@($meta.main_output_fields).Count) output fields" "$(@($complete.json.output_fields).Count) output fields" 'tests/scenarios/complete.json' 'compare validator output_fields to product_meta.main_output_fields'
if ($meta.calculator) {
    $calculatorCases = @(Get-Content -LiteralPath (Join-Path $repo 'tests\calculator-cases.json') -Raw | ConvertFrom-Json)
    Add-Check 'T4_DETERMINISTIC_FUNCTION' 'calculator_case_count' ($calculatorCases.Count -ge 1) 'at least 1 executed calculator case' $calculatorCases.Count 'tests/calculator-cases.json' 'load executable calculator case index'
    foreach ($case in $calculatorCases) {
        $casePath = Join-Path $repo $case.input_file
        $actual = Invoke-NodeJson (Join-Path $repo 'scripts\calculate.js') $casePath
        $expectedExit = if ($null -ne $case.expected_exit_code) { [int]$case.expected_exit_code } else { 0 }
        $passed = ($actual.exit_code -eq $expectedExit) -and (Test-JsonSubset $case.expected $actual.json)
        $layer = if ($case.layer) { $case.layer } else { 'T5_SCENARIO_TESTS' }
        Add-Check $layer "calculator:$($case.id)" $passed "exit=$expectedExit expected=$($case.expected | ConvertTo-Json -Depth 8 -Compress)" "exit=$($actual.exit_code) actual=$($actual.json | ConvertTo-Json -Depth 8 -Compress)" $case.input_file "node scripts/calculate.js $($case.input_file)"
    }
}

# T5 scenario tests
$scenarioExpectations = @(
    @{ file='missing.json'; status='NEEDS_INPUT'; exit=2 },
    @{ file='conflict.json'; status='NEEDS_CONFIRMATION'; exit=2 },
    @{ file='sensitive.json'; status='READY_WITH_PRIVACY_WARNING'; exit=0 },
    @{ file='malformed.txt'; status='INVALID_JSON'; exit=2 }
)
foreach ($scenario in $scenarioExpectations) {
    $actual = Invoke-NodeJson $inputValidator (Join-Path $repo "tests\scenarios\$($scenario.file)")
    $passed = $actual.exit_code -eq $scenario.exit -and $actual.json.validation_status -eq $scenario.status
    Add-Check 'T5_SCENARIO_TESTS' "scenario:$($scenario.file)" $passed "exit=$($scenario.exit) status=$($scenario.status)" "exit=$($actual.exit_code) status=$($actual.json.validation_status)" "tests/scenarios/$($scenario.file)" "node scripts/validate_input.js tests/scenarios/$($scenario.file)"
}

# T6 security
$textExtensions = @('.md','.json','.txt','.js','.ps1')
$textFiles = @(
    Get-ChildItem -LiteralPath $repo -File -Recurse -Force |
        Where-Object {
            $_.FullName -notmatch '\\\.git\\' -and
            $_.FullName -notmatch '\\tests\\validate_package\.ps1$' -and
            $_.Extension -in $textExtensions
        }
)
$secretPatterns = @(
    '-----BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY-----',
    'gh[pousr]_[A-Za-z0-9]{36,}',
    'github_pat_[A-Za-z0-9_]{50,}',
    'AKIA[0-9A-Z]{16}',
    '(?i)(api[_-]?key|secret|password|passwd)\s*[:=]\s*["''][^"'']{8,}["'']'
)
$paidApiPatterns = @(
    '(?i)api\.openai\.com',
    '(?i)api\.deepseek\.com',
    '(?i)OPENAI_API_KEY',
    '(?i)DEEPSEEK_API_KEY'
)
$internalPathPatterns = @(
    'E:\\金励泽科技',
    'JINLIZE_PROJECT_WORKSPACES',
    'C:\\Users\\'
)
$secretCount = 0
$paidApiCount = 0
$internalPathCount = 0
foreach ($file in $textFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $secretPatterns) { if ($content -match $pattern) { $secretCount++ } }
    foreach ($pattern in $paidApiPatterns) { if ($content -match $pattern) { $paidApiCount++ } }
    foreach ($pattern in $internalPathPatterns) { if ($content -match $pattern) { $internalPathCount++ } }
}
Add-Check 'T6_SECURITY' 'secret_patterns' ($secretCount -eq 0) '0' $secretCount
Add-Check 'T6_SECURITY' 'paid_api_dependency' ($paidApiCount -eq 0) '0' $paidApiCount
Add-Check 'T6_SECURITY' 'internal_paths' ($internalPathCount -eq 0) '0' $internalPathCount

# T7 package integrity
$packagePath = Join-Path $repo $meta.package_path
$packageManifest = Get-Content -LiteralPath (Join-Path $repo 'package-manifest.json') -Raw | ConvertFrom-Json
Add-Check 'T7_PACKAGE_INTEGRITY' 'zip_exists' (Test-Path -LiteralPath $packagePath) 'exists' 'checked'
$zipEntries = @()
$zipLicenseSha256 = $null
if (Test-Path -LiteralPath $packagePath) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $zipEntries = @($archive.Entries | ForEach-Object FullName)
        $licenseEntry = $archive.GetEntry("$($meta.repository_name)/LICENSE")
        if ($licenseEntry) {
            $reader = [System.IO.StreamReader]::new($licenseEntry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
            try {
                $licenseText = ($reader.ReadToEnd() -replace "`r`n", "`n")
                $zipLicenseSha256 = [System.BitConverter]::ToString(
                    [System.Security.Cryptography.SHA256]::HashData([System.Text.UTF8Encoding]::new($false).GetBytes($licenseText))
                ).Replace('-','')
            }
            finally { $reader.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
Add-Check 'T7_PACKAGE_INTEGRITY' 'package_entries' (@(Compare-Object -ReferenceObject (@($meta.package_entries) | Sort-Object) -DifferenceObject ($zipEntries | Sort-Object)).Count -eq 0) 'manifest entries equal zip entries' "$($zipEntries.Count) entries"
Add-Check 'T7_PACKAGE_INTEGRITY' 'license_in_zip' ($zipEntries -contains "$($meta.repository_name)/LICENSE") 'LICENSE' 'checked'
$repositoryLicenseSha256 = Get-NormalizedTextSha256 (Join-Path $repo 'LICENSE')
Add-Check 'T7_PACKAGE_INTEGRITY' 'license_manifest' ($packageManifest.license_included -eq $true -and $packageManifest.license_sha256 -eq $repositoryLicenseSha256) 'license registered with normalized SHA-256' "manifest=$($packageManifest.license_sha256) repository=$repositoryLicenseSha256"
Add-Check 'T7_PACKAGE_INTEGRITY' 'license_zip_matches_repository' ($zipLicenseSha256 -eq $repositoryLicenseSha256) $repositoryLicenseSha256 $zipLicenseSha256
Add-Check 'T7_PACKAGE_INTEGRITY' 'zip_sha256' ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -eq $packageManifest.sha256) $packageManifest.sha256 'checked'
Add-Check 'T7_PACKAGE_INTEGRITY' 'third_party_notice' ($zipEntries -contains "$($meta.repository_name)/THIRD_PARTY_NOTICES.md") 'THIRD_PARTY_NOTICES.md' 'checked'
Add-Check 'T7_PACKAGE_INTEGRITY' 'manifest_version' ($packageManifest.version -eq $version) $version $packageManifest.version
Add-Check 'T7_PACKAGE_INTEGRITY' 'package_state' ($packageManifest.status -eq 'GITHUB_PACKAGE_PRE_RELEASE_READY') 'GITHUB_PACKAGE_PRE_RELEASE_READY' $packageManifest.status

$layerStatus = [ordered]@{}
foreach ($layer in $layers.Keys) {
    $checks = @($layers[$layer])
    $layerStatus[$layer] = if ($checks.Count -gt 0 -and @($checks | Where-Object { -not $_.passed }).Count -eq 0) { 'PASS' } else { 'FAIL' }
}
$allLayersPassed = @($layerStatus.Values | Where-Object { $_ -ne 'PASS' }).Count -eq 0
$t5Mode = if ($meta.calculator) { 'PASS_DETERMINISTIC_SCENARIOS' } else { 'PASS_CONTRACT_ONLY' }
$runtimeStatus = 'NOT_RUNTIME_VERIFIED'

$result = [ordered]@{
    product_id = $meta.product_id
    repository_name = $meta.repository_name
    product_type = $meta.product_type
    version = $version
    tested_at = (Get-Date).ToString('o')
    tested_tree_sha = $TestedTreeSha
    package_path = $meta.package_path
    package_sha256 = if (Test-Path -LiteralPath $packagePath) { (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash } else { $null }
    layers = $layers
    layer_status = $layerStatus
    t5_execution_mode = $t5Mode
    model_runtime_status = $runtimeStatus
    overall_package_status = if ($allLayersPassed) { 'G9_PRE_RELEASE_ACCEPTED' } else { 'FAILED' }
    errors = @($errors)
}

New-Item -ItemType Directory -Path (Join-Path $repo 'test-results') -Force | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $repo "test-results\v$version.json") -Encoding utf8

$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine("# 产品测试报告 v$version")
[void]$report.AppendLine()
[void]$report.AppendLine("- 产品：$($meta.chinese_name)（$($meta.product_id)）")
[void]$report.AppendLine("- 包状态：$($result.overall_package_status)")
[void]$report.AppendLine("- 模型运行状态：$runtimeStatus")
[void]$report.AppendLine()
[void]$report.AppendLine('| 层级 | 状态 | 检查数 | 失败数 |')
[void]$report.AppendLine('|---|---|---:|---:|')
foreach ($layer in $layers.Keys) {
    $checks = @($layers[$layer])
    [void]$report.AppendLine("| $layer | $($layerStatus[$layer]) | $($checks.Count) | $(@($checks | Where-Object { -not $_.passed }).Count) |")
}
[void]$report.AppendLine()
[void]$report.AppendLine('## 失败明细')
[void]$report.AppendLine()
if ($errors.Count -eq 0) {
    [void]$report.AppendLine('- 无')
} else {
    foreach ($errorItem in $errors) { [void]$report.AppendLine("- $errorItem") }
}
[void]$report.AppendLine()
[void]$report.AppendLine('## 运行边界')
[void]$report.AppendLine()
if ($meta.calculator) {
    [void]$report.AppendLine('- T4/T5 包含实际 Node 计算脚本执行和输入边界场景执行。')
} else {
    [void]$report.AppendLine('- T4/T5 包含实际输入校验脚本和场景状态测试；生成式模型输出未在本地运行，标记 NOT_RUNTIME_VERIFIED。')
}
[void]$report.AppendLine('- WorkBuddy解析、安装、调用和审核未执行，不在本轮验收中冒充通过。')
Set-Content -LiteralPath (Join-Path $repo "tests\TEST_REPORT-v$version.md") -Value $report.ToString() -Encoding utf8

$acceptance = @"
# G5/G9 验收状态

- 产品编号：$($meta.product_id)
- 版本：$version
- 包状态：$($result.overall_package_status)
- G5状态：G5_STRENGTHENED
- 模型运行状态：NOT_RUNTIME_VERIFIED
- WorkBuddy验证：WORKBUDDY_VALIDATION_NOT_IN_SCOPE
- 包SHA-256：$($result.package_sha256)
- 测试报告：tests/TEST_REPORT-v$version.md
"@
Set-Content -LiteralPath (Join-Path $repo 'G5_G9_ACCEPTANCE.md') -Value $acceptance -Encoding utf8
Write-Output "TEST_STATUS=$($result.overall_package_status) ERRORS=$($errors.Count) T5=$t5Mode"
if (-not $allLayersPassed) { exit 1 }

