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
$checks = [ordered]@{}
$errors = [System.Collections.Generic.List[string]]::new()

function Check($Name, $Condition, $Message) {
    $script:checks[$Name] = [bool]$Condition
    if (-not $Condition) { $script:errors.Add($Message) }
}

function Test-JsonSubset($Expected, $Actual) {
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

foreach ($required in @('README.md','PRODUCT_SPEC.md','LICENSE','USAGE.md','CHANGELOG.md','VERSION','THIRD_PARTY_NOTICES.md','product_meta.json','package-manifest.json',$meta.package_path)) {
    Check "exists:$required" (Test-Path -LiteralPath (Join-Path $repo $required)) "Missing required file: $required"
}
Check 'version' ((Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim() -eq '1.0.0') 'VERSION is not 1.0.0.'
Check 'license_sha256' ((Get-FileHash -LiteralPath (Join-Path $repo 'LICENSE') -Algorithm SHA256).Hash -eq 'CFC7749B96F63BD31C3C42B5C471BF756814053E847C10F3EB003417BC523D30') 'LICENSE is not canonical Apache-2.0.'
$testCount = @(Select-String -LiteralPath (Join-Path $repo 'tests\TEST_CASES.md') -Pattern '^\| T0\d').Count
Check 'test_case_count' ($testCount -ge 5) 'Fewer than five test cases.'

if ($meta.product_type -eq 'Skill') {
    $skillPath = Join-Path $repo 'SKILL.md'
    $skill = (Get-Content -LiteralPath $skillPath -Raw) -replace "`r`n", "`n"
    Check 'skill_name' ($skill -match "(?m)^name:\s*$([regex]::Escape($meta.repository_name))$") 'SKILL name mismatch.'
    Check 'skill_display_name' ($skill -match "(?m)^display_name:\s*'") 'SKILL display_name missing.'
    Check 'skill_display_name_en' ($skill -match "(?m)^display_name_en:\s*'") 'SKILL display_name_en missing.'
    Check 'skill_description' ($skill -match '(?m)^description:\s*') 'SKILL description missing.'
    Check 'skill_description_zh' ($skill -match '(?m)^description_zh:\s*') 'SKILL description_zh missing.'
    Check 'skill_description_en' ($skill -match '(?m)^description_en:\s*') 'SKILL description_en missing.'
    Check 'skill_examples' ($skill.Contains('examples_zh:') -and $skill.Contains('examples_en:')) 'SKILL examples missing.'
    Check 'skill_version' ($skill -match '(?m)^version:\s*1\.0\.0$') 'SKILL version mismatch.'
    Check 'skill_author' ($skill -match "(?m)^author:\s*'广州金励泽科技服务有限公司'$") 'SKILL author mismatch.'
    Check 'skill_sections' ($skill.Contains('## 执行流程') -and $skill.Contains('## 输出要求') -and $skill.Contains('## 异常与安全')) 'SKILL required sections missing.'
    Check 'skill_product_specific' ($skill.Contains($meta.core_input) -or $skill.Contains($meta.main_output)) 'SKILL lacks product-specific contract.'
    Check 'skill_template' (Test-Path -LiteralPath (Join-Path $repo 'templates\OUTPUT_TEMPLATE.md')) 'Output template missing.'
    Check 'skill_references' ((Test-Path -LiteralPath (Join-Path $repo 'references\DOMAIN_GUIDE.md')) -and (Test-Path -LiteralPath (Join-Path $repo 'references\EXAMPLES.md'))) 'Skill references missing.'
    Check 'no_AGENT_md' (-not (Test-Path -LiteralPath (Join-Path $repo 'AGENT.md'))) 'AGENT.md must not exist.'
}
else {
    $pluginPath = Join-Path $repo '.codebuddy-plugin\plugin.json'
    Check 'plugin_exists' (Test-Path -LiteralPath $pluginPath) 'plugin.json missing.'
    if (Test-Path -LiteralPath $pluginPath) {
        $plugin = Get-Content -LiteralPath $pluginPath -Raw | ConvertFrom-Json
        Check 'plugin_type' ($plugin.expertType -eq 'agent') 'plugin expertType mismatch.'
        Check 'plugin_name' ($plugin.name -eq $meta.repository_name -and $plugin.agentName -eq $meta.repository_name) 'plugin name mismatch.'
        Check 'plugin_version' ($plugin.version -eq '1.0.0') 'plugin version mismatch.'
        Check 'plugin_category' ($plugin.categoryId -eq '15-Education') 'plugin category mismatch.'
        Check 'plugin_tags' (@($plugin.tags).Count -eq 3) 'plugin must have exactly three tags.'
        Check 'plugin_prompts' (@($plugin.quickPrompts).Count -eq 3) 'plugin must have exactly three quick prompts.'
        $len = ($plugin.displayDescription.zh.ToCharArray()).Length
        Check 'plugin_description_length' ($len -ge 40 -and $len -le 50) "displayDescription.zh length is $len, expected 40-50."
        Check 'plugin_default_prompt' ($plugin.defaultInitPrompt.zh -eq $plugin.quickPrompts[0].zh) 'defaultInitPrompt does not match first quick prompt.'
    }
    $agentPath = Join-Path $repo "agents\$($meta.repository_name).md"
    Check 'agent_definition' (Test-Path -LiteralPath $agentPath) 'Agent definition missing.'
    if (Test-Path -LiteralPath $agentPath) {
        $agent = (Get-Content -LiteralPath $agentPath -Raw) -replace "`r`n", "`n"
        Check 'agent_sections' ($agent.Contains('## 多步骤执行') -and $agent.Contains('## 异常处理与恢复') -and $agent.Contains('## 输出格式')) 'Agent required sections missing.'
        Check 'agent_product_specific' ($agent.Contains($meta.core_input) -or $agent.Contains($meta.main_output)) 'Agent lacks product-specific contract.'
        Check 'agent_name' ($agent -match "(?m)^name:\s*$([regex]::Escape($meta.repository_name))$") 'Agent definition name mismatch.'
        Check 'agent_max_turns' ($agent -match '(?m)^maxTurns:\s*50$') 'Agent maxTurns missing.'
    }
    $avatarPath = Join-Path $repo 'avatars\expert.png'
    Check 'avatar_exists' (Test-Path -LiteralPath $avatarPath) 'Agent avatar missing.'
    if (Test-Path -LiteralPath $avatarPath) {
        $avatarInfo = Get-Item -LiteralPath $avatarPath
        $image = [System.Drawing.Image]::FromFile($avatarPath)
        try {
            Check 'avatar_size_limit' ($avatarInfo.Length -le 512000) 'Avatar exceeds 500KB.'
            Check 'avatar_dimensions' ($image.Width -eq 512 -and $image.Height -eq 512) 'Avatar must be 512x512.'
        }
        finally { $image.Dispose() }
    }
    Check 'no_AGENT_md' (-not (Test-Path -LiteralPath (Join-Path $repo 'AGENT.md'))) 'AGENT.md must not exist.'
}

$packagePath = Join-Path $repo $meta.package_path
if (Test-Path -LiteralPath $packagePath) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $entries = @($archive.Entries | ForEach-Object FullName)
        $expectedEntries = @($meta.package_entries)
        $diff = @(Compare-Object -ReferenceObject ($expectedEntries | Sort-Object) -DifferenceObject ($entries | Sort-Object))
        Check 'package_entries' ($diff.Count -eq 0) "Package entry mismatch: $($diff | ConvertTo-Json -Compress)"
    }
    finally { $archive.Dispose() }
    $manifest = Get-Content -LiteralPath (Join-Path $repo 'package-manifest.json') -Raw | ConvertFrom-Json
    Check 'package_sha256' ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -eq $manifest.sha256) 'Package SHA-256 mismatch.'
}

$textFiles = @(
    Get-ChildItem -LiteralPath $repo -File -Recurse -Force |
        Where-Object {
            $_.FullName -notmatch '\\\.git\\' -and
            $_.FullName -notmatch '\\tests\\validate_package\.ps1$' -and
            $_.Extension -in @('.md','.json','.txt','.js','.ps1')
        }
)
$secretPatterns = @(
    '-----BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY-----',
    'gh[pousr]_[A-Za-z0-9]{36,}',
    'github_pat_[A-Za-z0-9_]{50,}',
    'AKIA[0-9A-Z]{16}',
    '(?i)(api[_-]?key|secret|password|passwd)\s*[:=]\s*["''][^"'']{8,}["'']'
)
$sensitiveMatches = 0
$externalApiMatches = 0
$externalApiPatterns = @(
    '(?i)api\.openai\.com',
    '(?i)api\.deepseek\.com',
    '(?i)OPENAI_API_KEY',
    '(?i)DEEPSEEK_API_KEY'
)
foreach ($file in $textFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $secretPatterns) {
        if ($content -match $pattern) { $sensitiveMatches++ }
    }
    foreach ($pattern in $externalApiPatterns) {
        if ($content -match $pattern) { $externalApiMatches++ }
    }
}
Check 'sensitive_data' ($sensitiveMatches -eq 0) "Sensitive patterns found: $sensitiveMatches"
Check 'no_paid_api_dependency' ($externalApiMatches -eq 0) "Paid API references found: $externalApiMatches"

if ($meta.calculator -and (Test-Path -LiteralPath (Join-Path $repo 'scripts\calculate.js'))) {
    $nodeOutput = & node (Join-Path $repo 'scripts\calculate.js') (Join-Path $repo 'tests\calculator-input.json') 2>&1
    Check 'calculator_execution' ($LASTEXITCODE -eq 0) "Calculator failed: $nodeOutput"
    if ($LASTEXITCODE -eq 0) {
        $actual = $nodeOutput | ConvertFrom-Json
        $expected = Get-Content -LiteralPath (Join-Path $repo 'tests\calculator-expected.json') -Raw | ConvertFrom-Json
        foreach ($property in $expected.PSObject.Properties.Name) {
            Check "calculator:$property" (Test-JsonSubset $expected.$property $actual.$property) "Calculator result mismatch for $property."
        }
    }
}

$passed = ($errors.Count -eq 0)
$result = [ordered]@{
    product_id = $meta.product_id
    repository_name = $meta.repository_name
    product_type = $meta.product_type
    version = '1.0.0'
    tested_at = (Get-Date).ToString('o')
    tested_tree_sha = $TestedTreeSha
    package_path = $meta.package_path
    package_sha256 = if (Test-Path -LiteralPath $packagePath) { (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash } else { $null }
    checks = $checks
    errors = @($errors)
    status = if ($passed) { 'PASS' } else { 'FAIL' }
}
New-Item -ItemType Directory -Path (Join-Path $repo 'test-results') -Force | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $repo 'test-results\v1.0.0.json') -Encoding utf8
Write-Output "TEST_STATUS=$($result.status) ERRORS=$($errors.Count)"
if (-not $passed) { exit 1 }
