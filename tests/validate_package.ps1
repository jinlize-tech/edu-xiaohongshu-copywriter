param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$TestedTreeSha,

    [switch]$Draft,

    [string]$DraftOutputDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$meta = Get-Content -LiteralPath (Join-Path $repo 'product_meta.json') -Raw | ConvertFrom-Json
$version = $meta.version
$dirtyBeforeTest = @(git -C $repo status --porcelain=v1)
if ($dirtyBeforeTest.Count -ne 0) {
    throw "Repository must be clean before testing so tested_tree_sha is bound to a real Git tree: $($dirtyBeforeTest -join '; ')"
}
$testedCommit = @(git -C $repo rev-parse HEAD)[0]
$actualHeadTree = @(git -C $repo rev-parse 'HEAD^{tree}')[0]
& git -C $repo cat-file -e "$TestedTreeSha^{tree}" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "tested_tree_sha does not exist in repository: $TestedTreeSha"
}
if ($TestedTreeSha -ne $actualHeadTree) {
    throw "tested_tree_sha mismatch: provided=$TestedTreeSha actual HEAD tree=$actualHeadTree"
}
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
        version = $version
        tested_commit = $testedCommit
        tested_tree_sha = $TestedTreeSha
        evidence_mode = if ($Draft) { 'CONTRACT_AND_SCENARIO_TESTED' } else { 'PRE_RELEASE_ACCEPTANCE_CHECK' }
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
    'USER_EXPERIENCE.md',
    'references/PROFESSIONAL_PLAYBOOK.md',
    'EDUCATION_1.1.0_UPGRADE_RECORD.md',
    $meta.package_path,
    'tests/TEST_CASES.md',
    'tests/validate_package.ps1',
    'tests/scenarios/complete.json',
    'tests/scenarios/missing.json',
    'tests/scenarios/conflict.json',
    'tests/scenarios/sensitive.json',
    'tests/scenarios/malformed.txt',
    'tests/scenarios/normal.json',
    'tests/scenarios/incomplete.json',
    'tests/scenarios/complex.json',
    'tests/scenarios/scenario_manifest.json',
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
Add-Check 'T2_METADATA_CONTRACT' 'version_110' ($version -eq '1.1.0') '1.1.0' $version
Add-Check 'T2_METADATA_CONTRACT' 'previous_version' ($meta.previous_version -eq '1.0.2') '1.0.2' $meta.previous_version
Add-Check 'T2_METADATA_CONTRACT' 'status' ($meta.status -eq 'EDUCATION_1.1.0_PRE_RELEASE_ACCEPTED') 'EDUCATION_1.1.0_PRE_RELEASE_ACCEPTED' $meta.status
Add-Check 'T2_METADATA_CONTRACT' 'upgrade_status' ($meta.upgrade_status -eq 'EDUCATION_1.1.0_DEEP_UPGRADE') 'EDUCATION_1.1.0_DEEP_UPGRADE' $meta.upgrade_status
Add-Check 'T2_METADATA_CONTRACT' 'contract_status' ($meta.contract_status -eq 'CONTRACT_VERIFIED') 'CONTRACT_VERIFIED' $meta.contract_status
Add-Check 'T2_METADATA_CONTRACT' 'deterministic_status' ($meta.deterministic_status -eq 'DETERMINISTIC_TESTED') 'DETERMINISTIC_TESTED' $meta.deterministic_status
Add-Check 'T2_METADATA_CONTRACT' 'scenario_status' ($meta.scenario_status -eq 'SCENARIO_TESTED') 'SCENARIO_TESTED' $meta.scenario_status
Add-Check 'T2_METADATA_CONTRACT' 'runtime_status' ($meta.runtime_status -eq 'MODEL_RUNTIME_NOT_VERIFIED') 'MODEL_RUNTIME_NOT_VERIFIED' $meta.runtime_status
Add-Check 'T2_METADATA_CONTRACT' 'workbuddy_status' ($meta.workbuddy_validation -eq 'WORKBUDDY_VALIDATION_NOT_IN_SCOPE') 'WORKBUDDY_VALIDATION_NOT_IN_SCOPE' $meta.workbuddy_validation
Add-Check 'T2_METADATA_CONTRACT' 'package_state' ($meta.package_state -eq 'GITHUB_PACKAGE_V1.1.0_PRE_RELEASE_READY') 'GITHUB_PACKAGE_V1.1.0_PRE_RELEASE_READY' $meta.package_state
Add-Check 'T2_METADATA_CONTRACT' 'baseline_commit' ($meta.baseline_commit -match '^[0-9a-f]{40}$') '40-char commit SHA' $meta.baseline_commit
Add-Check 'T2_METADATA_CONTRACT' 'previous_commit' ($meta.previous_commit -match '^[0-9a-f]{40}$') '40-char commit SHA' $meta.previous_commit
Add-Check 'T2_METADATA_CONTRACT' 'main_output_fields' (@($meta.main_output_fields).Count -gt 0) 'at least one output field' @($meta.main_output_fields).Count
$changeLogText = Get-NormalizedText (Join-Path $repo 'CHANGELOG.md')
Add-Check 'T2_METADATA_CONTRACT' 'changelog_110' ($changeLogText.Contains('## 1.1.0 - 2026-11-08')) '1.1.0 changelog entry' 'checked'
$readmeText = Get-NormalizedText (Join-Path $repo 'README.md')
Add-Check 'T2_METADATA_CONTRACT' 'readme_upgrade_status' ($readmeText.Contains('EDUCATION_1.1.0_PRE_RELEASE_ACCEPTED') -and $readmeText.Contains('MODEL_RUNTIME_NOT_VERIFIED')) '1.1.0 status in README' 'checked'

$baselineIdentity = Get-NormalizedText (Join-Path $repo 'BASELINE_VERSION.md')
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_marker' ($baselineIdentity.Contains('## Current Main Identity Supplement (v1.0.2)')) 'v1.0.2 supplement marker' 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_product_id' ($baselineIdentity.Contains("- Product ID: ``$($meta.product_id)``")) $meta.product_id 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_product_name' ($baselineIdentity.Contains("- Product name (Chinese): ``$($meta.chinese_name)``")) $meta.chinese_name 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_product_type' ($baselineIdentity.Contains("- Product type: ``$($meta.product_type)``")) $meta.product_type 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_business_section' ($baselineIdentity.Contains("Business section: ``$($meta.category)``")) $meta.category 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_baseline_commit' ($baselineIdentity.Contains("- Baseline commit: ``$($meta.baseline_commit)``")) $meta.baseline_commit 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_baseline_tag' ($baselineIdentity.Contains('education-product-baseline-v1.0.0')) 'education-product-baseline-v1.0.0' 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_spec_sha' ($baselineIdentity.Contains("Product specification SHA-256: ``$(Get-NormalizedTextSha256 (Join-Path $repo 'PRODUCT_SPEC.md'))``")) 'normalized PRODUCT_SPEC.md SHA-256' 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_license' ($baselineIdentity.Contains('Apache-2.0')) 'Apache-2.0' 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_license_sha' ($baselineIdentity.Contains("LICENSE SHA-256: ``$((Get-FileHash -LiteralPath (Join-Path $repo 'LICENSE') -Algorithm SHA256).Hash)``")) 'LICENSE SHA-256' 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'baseline_identity_audit' ($baselineIdentity.Contains('Audit status: PASS')) 'PASS' 'checked'

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
    $professionMatch = [regex]::Match($agent, "(?ms)^profession:\s*\r?\n\s+en:\s*'([^']*)'\s*\r?\n\s+zh:\s*'([^']*)'")
    $agentProfessionZh = if ($professionMatch.Success) { $professionMatch.Groups[2].Value.Trim() } else { '' }
    Add-Check 'T2_METADATA_CONTRACT' 'agent_profession_zh_present' (-not [string]::IsNullOrWhiteSpace($agentProfessionZh)) 'non-empty profession.zh' $agentProfessionZh
    Add-Check 'T2_METADATA_CONTRACT' 'agent_profession_zh_specific' ($agentProfessionZh.Length -ge 4 -and $agentProfessionZh -match '专家$' -and $agentProfessionZh -ne '专家') 'specific Chinese profession ending with 专家' $agentProfessionZh
    Add-Check 'T2_METADATA_CONTRACT' 'plugin_profession_zh_present' (-not [string]::IsNullOrWhiteSpace([string]$plugin.profession.zh)) 'non-empty profession.zh' ([string]$plugin.profession.zh)
    Add-Check 'T2_METADATA_CONTRACT' 'profession_plugin_agent_match' ([string]$plugin.profession.zh -eq $agentProfessionZh) 'plugin.json == Agent front matter' "plugin=$($plugin.profession.zh); agent=$agentProfessionZh"
    Add-Check 'T2_METADATA_CONTRACT' 'profession_meta_match' ([string]$meta.profession_zh -eq $agentProfessionZh) 'product_meta.json == Agent front matter' "meta=$($meta.profession_zh); agent=$agentProfessionZh"
    $avatar = Get-Item -LiteralPath (Join-Path $repo 'avatars\expert.png')
    $image = [System.Drawing.Image]::FromFile($avatar.FullName)
    try {
        Add-Check 'T2_METADATA_CONTRACT' 'avatar_size' ($avatar.Length -le 512000) '<=512000' $avatar.Length
        Add-Check 'T2_METADATA_CONTRACT' 'avatar_dimensions' ($image.Width -eq 512 -and $image.Height -eq 512) '512x512' "$($image.Width)x$($image.Height)"
    }
    finally { $image.Dispose() }
}

# Upgrade-evidence contract
$upgradeRecord = Get-NormalizedText (Join-Path $repo 'EDUCATION_1.1.0_UPGRADE_RECORD.md')
$forbiddenRecordPatterns = @('\$BaselineCommit', '\(@\{.*repository_name', 'System\.Object\[\]', 'PENDING_IMPLEMENTATION_COMMIT', 'VERIFICATION_PENDING')
foreach ($pattern in $forbiddenRecordPatterns) {
    Add-Check 'T2_METADATA_CONTRACT' "upgrade_record_forbidden:$pattern" (-not ($upgradeRecord -match $pattern)) 'absent' 'checked'
}
Add-Check 'T2_METADATA_CONTRACT' 'upgrade_record_product' ($upgradeRecord.Contains($meta.product_id) -and $upgradeRecord.Contains($meta.chinese_name)) "$($meta.product_id) $($meta.chinese_name)" 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'upgrade_record_versions' ($upgradeRecord.Contains('1.0.2') -and $upgradeRecord.Contains('1.1.0')) '1.0.2 -> 1.1.0' 'checked'
Add-Check 'T2_METADATA_CONTRACT' 'upgrade_record_boundaries' ($upgradeRecord.Contains('MODEL_RUNTIME_NOT_VERIFIED') -and $upgradeRecord.Contains('WORKBUDDY_VALIDATION_NOT_IN_SCOPE')) 'runtime and WorkBuddy boundaries' 'checked'

# T3 product contract
$primaryTextPath = if ($meta.product_type -eq 'Skill') { Join-Path $repo 'SKILL.md' } else { Join-Path $repo "agents\$($meta.repository_name).md" }
$primary = Get-NormalizedText $primaryTextPath
$domainGuide = Get-NormalizedText (Join-Path $repo 'templates\OUTPUT_TEMPLATE.md')
$userExperience = Get-NormalizedText (Join-Path $repo 'USER_EXPERIENCE.md')
$professionalPlaybook = Get-NormalizedText (Join-Path $repo 'references\PROFESSIONAL_PLAYBOOK.md')
Add-Check 'T3_PRODUCT_CONTRACT' 'workflow' ($primary.Contains('执行流程') -or $primary.Contains('多步骤执行')) 'workflow section' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'product_specific_rules' ($primary.Contains('产品专属') -and $primary.Contains('去重边界')) 'product-specific rules and dedup boundary' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'traceability_matrix' ($primary.Contains('核对矩阵') -or $primary.Contains('映射')) 'input-to-output mapping' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'minimum_questions' ($primary.Contains('最多3个') -or $primary.Contains('最多提出3个')) 'at most 3 critical questions' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'ux_first_use' ($userExperience.Contains('首次使用') -and $userExperience.Contains('最少输入')) 'first-use guidance and minimum input' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'ux_delivery_loop' ($userExperience.Contains('交付阶段') -and $userExperience.Contains('修订')) 'delivery and revision loop' 'checked'
Add-Check 'T3_PRODUCT_CONTRACT' 'professional_playbook' ($professionalPlaybook.Contains('任务专属判断规则') -and $professionalPlaybook.Contains('输入证据矩阵') -and $professionalPlaybook.Contains('输出验收表')) 'task rules, evidence matrix, output acceptance' 'checked'
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
        $passed = ($actual.exit_code -eq $expectedExit) -and
            ($actual.json.formula_version -eq $version) -and
            (Test-JsonSubset $case.expected $actual.json)
        $layer = if ($case.layer) { $case.layer } else { 'T5_SCENARIO_TESTS' }
        Add-Check $layer "calculator:$($case.id)" $passed "exit=$expectedExit expected=$($case.expected | ConvertTo-Json -Depth 8 -Compress)" "exit=$($actual.exit_code) actual=$($actual.json | ConvertTo-Json -Depth 8 -Compress)" $case.input_file "node scripts/calculate.js $($case.input_file)"
    }
}

# T5 scenario tests
$scenarioExpectations = @(
    @{ file='normal.json'; status='READY_FOR_PROCESSING'; exit=0; scenario='normal' },
    @{ file='incomplete.json'; status='NEEDS_INPUT'; exit=2; scenario='incomplete' },
    @{ file='complex.json'; status='NEEDS_CONFIRMATION'; exit=2; scenario='complex' },
    @{ file='sensitive.json'; status='READY_WITH_PRIVACY_WARNING'; exit=0; scenario='sensitive' },
    @{ file='malformed.txt'; status='INVALID_JSON'; exit=2; scenario=$null }
)
foreach ($scenario in $scenarioExpectations) {
    $actual = Invoke-NodeJson $inputValidator (Join-Path $repo "tests\scenarios\$($scenario.file)")
    $passed = $actual.exit_code -eq $scenario.exit -and
        $actual.json.validation_status -eq $scenario.status -and
        ($null -eq $scenario.scenario -or $actual.json.scenario_name -eq $scenario.scenario)
    Add-Check 'T5_SCENARIO_TESTS' "scenario:$($scenario.file)" $passed "exit=$($scenario.exit) status=$($scenario.status)" "exit=$($actual.exit_code) status=$($actual.json.validation_status)" "tests/scenarios/$($scenario.file)" "node scripts/validate_input.js tests/scenarios/$($scenario.file)"
}
$scenarioManifest = @(Get-Content -LiteralPath (Join-Path $repo 'tests\scenarios\scenario_manifest.json') -Raw | ConvertFrom-Json)
Add-Check 'T5_SCENARIO_TESTS' 'scenario_manifest' ($scenarioManifest.Count -ge 3) 'at least 3 differentiated business scenarios' $scenarioManifest.Count
foreach ($requiredScenario in @('normal','incomplete','complex')) {
    Add-Check 'T5_SCENARIO_TESTS' "scenario_declared:$requiredScenario" (@($scenarioManifest | Where-Object id -eq $requiredScenario).Count -eq 1) 'declared once' 'checked'
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
Add-Check 'T7_PACKAGE_INTEGRITY' 'input_validator_in_zip' ($zipEntries -contains "$($meta.repository_name)/scripts/validate_input.js") 'scripts/validate_input.js' 'checked'
if ($meta.product_type -eq 'Agent') {
    Add-Check 'T7_PACKAGE_INTEGRITY' 'agent_helper_in_zip' ($zipEntries -contains "$($meta.repository_name)/skills/$($meta.repository_name)-core/SKILL.md") 'Agent helper SKILL.md' 'checked'
    Add-Check 'T7_PACKAGE_INTEGRITY' 'agent_helper_validator_in_zip' ($zipEntries -contains "$($meta.repository_name)/skills/$($meta.repository_name)-core/scripts/validate_input.js") 'Agent helper validator' 'checked'
}
Add-Check 'T7_PACKAGE_INTEGRITY' 'manifest_version' ($packageManifest.version -eq $version) $version $packageManifest.version
Add-Check 'T7_PACKAGE_INTEGRITY' 'package_state' ($packageManifest.status -eq 'GITHUB_PACKAGE_V1.1.0_PRE_RELEASE_READY') 'GITHUB_PACKAGE_V1.1.0_PRE_RELEASE_READY' $packageManifest.status
Add-Check 'T7_PACKAGE_INTEGRITY' 'runtime_status' ($packageManifest.runtime_status -eq 'MODEL_RUNTIME_NOT_VERIFIED') 'MODEL_RUNTIME_NOT_VERIFIED' $packageManifest.runtime_status

$layerStatus = [ordered]@{}
foreach ($layer in $layers.Keys) {
    $checks = @($layers[$layer])
    $layerStatus[$layer] = if ($checks.Count -gt 0 -and @($checks | Where-Object { -not $_.passed }).Count -eq 0) { 'PASS' } else { 'FAIL' }
}
$allLayersPassed = @($layerStatus.Values | Where-Object { $_ -ne 'PASS' }).Count -eq 0
$t5Mode = if ($meta.calculator) { 'PASS_DETERMINISTIC_SCENARIOS' } else { 'PASS_CONTRACT_ONLY' }
$runtimeStatus = 'MODEL_RUNTIME_NOT_VERIFIED'
$resultStatus = if (-not $allLayersPassed) { 'FAILED' } else { 'EDUCATION_1.1.0_PRE_RELEASE_ACCEPTED' }

$result = [ordered]@{
    product_id = $meta.product_id
    repository_name = $meta.repository_name
    product_type = $meta.product_type
    version = $version
    tested_commit = $testedCommit
    tested_at = (Get-Date).ToString('o')
    tested_tree_sha = $TestedTreeSha
    package_path = $meta.package_path
    package_sha256 = if (Test-Path -LiteralPath $packagePath) { (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash } else { $null }
    layers = $layers
    layer_status = $layerStatus
    t5_execution_mode = $t5Mode
    model_runtime_status = $runtimeStatus
    upgrade_status = 'EDUCATION_1.1.0_DEEP_UPGRADE'
    verification_states = [ordered]@{
        static = 'STATIC_VERIFIED'
        contract = 'CONTRACT_VERIFIED'
        deterministic = 'DETERMINISTIC_TESTED'
        scenario = 'SCENARIO_TESTED'
        model_runtime = 'MODEL_RUNTIME_NOT_VERIFIED'
        workbuddy = 'WORKBUDDY_VALIDATION_NOT_IN_SCOPE'
    }
    overall_package_status = $resultStatus
    evidence_mode = 'TESTED_COMMIT_WITH_POST_TEST_EVIDENCE'
    errors = @($errors)
}

$resultDirectory = if ($Draft) {
    if (-not $DraftOutputDirectory) { throw 'DraftOutputDirectory is required in Draft mode.' }
    $DraftOutputDirectory
}
else {
    Join-Path $repo 'test-results'
}
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
$resultSuffix = if ($Draft) { '-draft' } else { '' }
$resultPath = Join-Path $resultDirectory "v$version$resultSuffix.json"
$result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resultPath -Encoding utf8

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
    [void]$report.AppendLine('- T4/T5 包含实际输入校验脚本和场景状态测试；生成式模型输出未在本地运行，标记 MODEL_RUNTIME_NOT_VERIFIED。')
}
[void]$report.AppendLine('- WorkBuddy解析、安装、调用和审核未执行，不在本轮验收中冒充通过。')
$reportSuffix = if ($Draft) { '-draft' } else { '' }
$reportPath = Join-Path $resultDirectory "TEST_REPORT-v$version$reportSuffix.md"
Set-Content -LiteralPath $reportPath -Value $report.ToString() -Encoding utf8

$acceptance = @"
# EDUCATION 1.1.0 验收状态

- 产品编号：$($meta.product_id)
- 版本：$version
- 包状态：$($result.overall_package_status)
- 升级状态：EDUCATION_1.1.0_DEEP_UPGRADE
- 模型运行状态：MODEL_RUNTIME_NOT_VERIFIED
- WorkBuddy验证：WORKBUDDY_VALIDATION_NOT_IN_SCOPE
- 被测Commit：$($result.tested_commit)
- 被测Tree：$($result.tested_tree_sha)
- 包SHA-256：$($result.package_sha256)
- 测试报告：test-results/TEST_REPORT-v$version.md
"@
if (-not $Draft) {
    Set-Content -LiteralPath (Join-Path $repo 'EDUCATION_1.1.0_ACCEPTANCE.md') -Value $acceptance -Encoding utf8
}
Write-Output "TEST_STATUS=$($result.overall_package_status) MODE=$(if ($Draft) {'DRAFT'} else {'FINAL'}) ERRORS=$($errors.Count) T5=$t5Mode"
if (-not $allLayersPassed) { exit 1 }

