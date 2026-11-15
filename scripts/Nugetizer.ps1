param([ValidateSet('prepare', 'build', 'preflight', 'publish', 'release')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Dotnet([string[]]$Arguments) {
    & dotnet @Arguments | Out-Host
    if ($LASTEXITCODE) { throw "dotnet $($Arguments[0]) failed ($LASTEXITCODE)." }
}

function Get-Version([string]$Value, [string]$Tag) {
    if (!$Value) { $Value = $Tag -creplace '^v', '' }
    if ($Value -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?\z' -or $Value -match '^0\.0\.0(?:-|$)') { throw 'Use a release version: major.minor.patch[-prerelease].' }
    foreach ($number in ($Value -split '-')[0].Split('.')) {
        $parsed = 0; if (![int]::TryParse($number, [ref]$parsed)) { throw 'Version components must fit a NuGet integer.' }
    }
    foreach ($part in (($Value -split '-', 2 | Select-Object -Skip 1) -split '\.')) {
        if ($part -match '^0\d+$') { throw 'Numeric prerelease identifiers cannot have leading zeroes.' }
    }
    return $Value
}

function Get-Stages([string]$Value) {
    $stages = @($Value -split '[,\s]+' | Where-Object { $_ })
    if (!$stages.Count -or @($stages | Where-Object { $_ -cnotin @('checkout','setup','test','pack','integration','archive','publish','release') }).Count) { throw 'Unknown or empty stages list.' }
    if ('integration' -in $stages -and 'pack' -notin $stages) { throw 'integration requires pack.' }
    if ('publish' -in $stages -and 'pack' -notin $stages) { throw 'publish requires pack.' }
    if ('archive' -in $stages -and 'pack' -notin $stages) { throw 'archive requires pack.' }
    if ('release' -in $stages -and 'publish' -notin $stages) { throw 'release requires publish.' }
    return $stages
}

function Get-Packages([string]$Directory, [string]$Version) {
    $files = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object Extension -in @('.nupkg','.snupkg') | Sort-Object Name)
    if (!@($files | Where-Object Extension -eq '.nupkg').Count) { throw 'No packages produced.' }
    $seen = @{}
    foreach ($file in $files) {
        if ($file.Extension -cnotin @('.nupkg','.snupkg')) { throw 'Use lowercase package extensions.' }
        $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
        try {
            $specs = @($zip.Entries | Where-Object FullName -match '^[^/]+\.nuspec$')
            if ($specs.Count -ne 1 -or $specs[0].Length -gt 1MB) { throw 'Expected one root nuspec, at most 1 MiB.' }
            $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = 'Prohibit'; $settings.XmlResolver = $null
            $stream = $specs[0].Open(); $reader = [Xml.XmlReader]::Create($stream, $settings)
            try {
                $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader)
                $meta = $xml.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]')
                $id = $meta.SelectSingleNode('*[local-name()="id"]').InnerText
                $actual = $meta.SelectSingleNode('*[local-name()="version"]').InnerText
            } finally { $reader.Dispose(); $stream.Dispose() }
        } finally { $zip.Dispose() }
        if ($id -notmatch '^[A-Za-z0-9_.-]+$' -or $actual -cne $Version) { throw "Unexpected package $id/$actual; expected $Version." }
        $key = "$id/$($file.Extension)"
        if ($seen.ContainsKey($key)) { throw "Duplicate package $key." }
        $seen[$key] = $file.Name
        if ($file.Extension -eq '.snupkg' -and (!$seen.ContainsKey("$id/.nupkg") -or $seen["$id/.nupkg"] -cne ([IO.Path]::ChangeExtension($file.Name, '.nupkg')))) { throw 'Symbols require an adjacent matching nupkg.' }
        [pscustomobject]@{ File = $file.Name; Id = $id; Version = $actual; Hash = (Get-FileHash -LiteralPath $file.FullName).Hash }
    }
}

function Get-PackProjects([string]$Target) {
    if (!$Target) { $Target = '.' }
    if (Test-Path -LiteralPath $Target -PathType Container) {
        $solutions = @(Get-ChildItem -LiteralPath $Target -File | Where-Object Extension -in @('.sln','.slnx'))
        $candidates = @(if ($solutions.Count) { $solutions } else { Get-ChildItem -LiteralPath $Target -Filter '*.csproj' -File })
        if ($candidates.Count -ne 1) { throw 'pack-target must identify one project or solution.' }
        $Target = $candidates[0].FullName
    }
    $path = (Resolve-Path -LiteralPath $Target).Path
    if ([IO.Path]::GetExtension($path) -eq '.csproj') { return $path }
    if ([IO.Path]::GetExtension($path) -notin @('.sln','.slnx')) { throw 'pack-target must be a .csproj, .sln or .slnx.' }
    $lines = @(& dotnet sln $path list)
    if ($LASTEXITCODE) { throw 'Could not enumerate solution projects.' }
    $projects = @($lines | Where-Object { $_.Trim().EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [IO.Path]::GetFullPath($_.Trim(), [IO.Path]::GetDirectoryName($path)) })
    if (!$projects.Count) { throw 'No C# projects found in pack solution.' }
    return $projects
}

function Get-ProjectMetadata([string]$Project, [string]$Configuration, [string[]]$ExtraProperties = @()) {
    $json = & dotnet msbuild $Project "-p:Configuration=$Configuration" @ExtraProperties '-getProperty:IsTestProject,IsTestingPlatformApplication,NugetizerIntegrationTest,IsPackable' -verbosity:quiet
    if ($LASTEXITCODE) { throw "Could not evaluate project metadata: $Project" }
    $properties = ($json | ConvertFrom-Json -AsHashtable)['Properties']
    foreach ($name in @('IsTestProject','IsTestingPlatformApplication','NugetizerIntegrationTest','IsPackable')) {
        if ($properties[$name] -and $properties[$name] -notin @('true','false')) { throw "Invalid $name in $Project; use true or false." }
    }
    return $properties
}

function Pack-Projects([string[]]$Projects, [string]$Configuration, [string]$Version, [string]$Destination) {
    $staging = Join-Path $Destination ('pack-' + [guid]::NewGuid().ToString('N'))
    $inventory = @(); $ids = @{}; $names = @{}
    foreach ($project in $Projects) {
        $output = Join-Path $staging ([guid]::NewGuid().ToString('N'))
        $properties = @("-p:Version=$Version", "-p:PackageVersion=$Version", "-p:RepositoryCommit=$env:GITHUB_SHA", "-p:PackageOutputPath=$output")
        if ((Get-ProjectMetadata $project $Configuration $properties)['IsPackable'] -ne 'true') { continue }
        Invoke-Dotnet (@('pack',$project,'-c',$Configuration) + $properties + @('-o',$output))
        if (!(Test-Path -LiteralPath $output)) { throw "Packable project produced no output: $project" }
        $files = @(Get-ChildItem -LiteralPath $output -File | Where-Object Extension -in @('.nupkg','.snupkg'))
        if (!$files.Count) { throw "Packable project produced no packages: $project" }
        foreach ($package in Get-Packages $output $Version) {
            $key = "$($package.Id)/$([IO.Path]::GetExtension($package.File))"
            if ($ids.ContainsKey($key) -or $names.ContainsKey($package.File) -or (Test-Path -LiteralPath (Join-Path $Destination $package.File))) { throw "Duplicate package output: $key ($($package.File))." }
            $ids[$key] = $true; $names[$package.File] = $true
            $inventory += Join-Path $output $package.File
        }
    }
    if (!$inventory.Count) { throw 'No packable projects produced packages.' }
    foreach ($file in $inventory) { Copy-Item -LiteralPath $file -Destination $Destination }
}

function Assert-LocalPackages([string]$Root, [string]$Feed, [string]$Cache, [string]$Version = '0.0.0-debug') {
    $packages = @(Get-Packages $Feed $Version | Where-Object { [IO.Path]::GetExtension($_.File) -eq '.nupkg' })
    $assetFiles = @(Get-ChildItem -LiteralPath $Root -Filter project.assets.json -Recurse -File)
    if (!$assetFiles.Count) { throw 'No restore assets found in the run artifacts directory.' }
    $verified = 0
    foreach ($file in $assetFiles) {
        $assets = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in $assets.libraries.Keys | Where-Object { $id = ($_ -split '/')[0]; $assets.libraries[$_]['type'] -eq 'package' -and $id -in $packages.Id }) {
            $package = @($packages | Where-Object { "$($_.Id)/$Version" -eq $key })
            if ($package.Count -ne 1) { throw "Candidate dependency $key does not use version $Version." }
            $library = $assets.libraries[$key]; $resolved = $null
            foreach ($folder in $assets.packageFolders.Keys) {
                $path = Join-Path (Join-Path $folder $library.path) "$($package[0].Id.ToLowerInvariant()).$($Version.ToLowerInvariant()).nupkg"
                if (Test-Path -LiteralPath $path) { $resolved = $path; break }
            }
            $expected = Join-Path (Join-Path $Cache $library.path) "$($package[0].Id.ToLowerInvariant()).$($Version.ToLowerInvariant()).nupkg"
            if (!$resolved -or [IO.Path]::GetFullPath($resolved) -ne [IO.Path]::GetFullPath($expected) -or (Get-FileHash -LiteralPath $resolved).Hash -ne $package[0].Hash) {
                throw "Local package $key did not resolve from this run's fresh cache. Remove fallback overrides or map the local feed correctly."
            }
            $verified++
        }
    }
    if (!$verified) { throw 'Integration target references no candidate package; use an exact PackageReference to a staged package.' }
}

function Assert-NewRelease {
    $json = & gh api "repos/$env:GITHUB_REPOSITORY/releases" --paginate --slurp
    if ($LASTEXITCODE) { throw 'Could not list GitHub releases.' }
    $existing = @($json | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.tag_name -ceq $env:GITHUB_REF_NAME })
    if ($existing.Count) { throw "Release $env:GITHUB_REF_NAME already exists (draft=$($existing[0].draft), prerelease=$($existing[0].prerelease)); follow README recovery guidance." }
}

function Invoke-Tests([string]$Target, [string[]]$Extra = @()) {
    $globalJson = if (Test-Path global.json) { Get-Content global.json -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $config = $globalJson['test']; $sdk = & dotnet --version
    if ($LASTEXITCODE -or $sdk -notmatch '^([0-9]+)\.') { throw 'Could not determine selected SDK.' }
    $runner = if ([int]$Matches[1] -ge 11 -and $env:DOTNET_TEST_RUNNER -in @('VSTest','Microsoft.Testing.Platform')) { $env:DOTNET_TEST_RUNNER } elseif ($config -is [Collections.IDictionary] -and $config.Contains('runner')) { $config['runner'] } else { 'VSTest' }
    $args = @('test')
    if ($Target) {
        if ($runner -eq 'Microsoft.Testing.Platform') { $args += $(if ($Target -match '\.slnx?$') { '--solution' } else { '--project' }) }
        $args += $Target
    }
    Invoke-Dotnet ($args + $Extra)
}

function Get-TestProjects([bool]$Integration, [string]$Target = '') {
    $projects = if ($Target) { @(Get-PackProjects $Target) } else { @(Get-ChildItem tests -Filter '*.csproj' -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](bin|obj|artifacts)[\\/]' } | Sort-Object FullName | ForEach-Object FullName) }
    $selected = @()
    foreach ($project in $projects) {
        $metadata = Get-ProjectMetadata $project $(if ($Integration) { 'Release' } else { 'Debug' })
        $isIntegration = $metadata['NugetizerIntegrationTest'] -eq 'true'
        if ($metadata['IsTestProject'] -eq 'true' -or $metadata['IsTestingPlatformApplication'] -eq 'true' -or $isIntegration) {
            if ($Target -and $isIntegration -ne $Integration) { throw "Test target $project belongs to the other test phase." }
            if ($isIntegration -eq $Integration) { $selected += $project }
        }
    }
    if (!$selected.Count) { throw 'No matching test projects; set IsTestProject/NugetizerIntegrationTest or omit the stage.' }
    return $selected
}

function Invoke-Pipeline([string]$Phase) {
    $stages = @(Get-Stages $env:NG_STAGES)
    $version = if ('pack' -in $stages) { Get-Version $env:NG_VERSION $env:GITHUB_REF_NAME } else { '' }
    if ($Phase -eq 'prepare') {
        if ('publish' -in $stages -and !$env:NG_USER) { throw 'Set NUGET_USER or nuget-user.' }
        if ('release' -in $stages -and $env:GITHUB_REF_TYPE -ne 'tag') { throw 'release requires a tag.' }
        if ('release' -in $stages -and $version -cne (Get-Version '' $env:GITHUB_REF_NAME)) { throw 'Release version must match its tag.' }
        $directory = Join-Path $env:RUNNER_TEMP ("nugetizer-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $directory | Out-Null
        "directory=$directory" >> $env:GITHUB_OUTPUT
        "version=$version" >> $env:GITHUB_OUTPUT
        "prerelease=$($version.Contains('-').ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT
        foreach ($stage in $stages) { "$stage=true" >> $env:GITHUB_OUTPUT }
        return
    }
    $directory = $env:NG_DIRECTORY
    if ($Phase -eq 'preflight') { Assert-NewRelease; return }
    if ($Phase -eq 'build') {
        Push-Location $env:NG_ROOT
        $cache = $env:NUGET_PACKAGES
        try {
            $env:NUGET_PACKAGES = Join-Path $directory 'cache'
            if ('test' -in $stages) {
                $targets = @(Get-TestProjects $false $env:NG_TEST)
                foreach ($target in $targets) { Invoke-Tests $target @('-c','Debug') }
            }
            if ('pack' -in $stages) {
                Pack-Projects @(Get-PackProjects $env:NG_PACK) 'Release' $version $directory
                @(Get-Packages $directory $version) | ConvertTo-Json -AsArray | Set-Content (Join-Path $directory 'manifest.json')
            }
            if ('integration' -in $stages) {
                $targets = @(Get-TestProjects $true $env:NG_INTEGRATION)
                foreach ($target in $targets) {
                    $artifacts = Join-Path $directory ('integration-' + [guid]::NewGuid().ToString('N'))
                    $properties = @('-p:UseArtifactsOutput=true', "-p:ArtifactsPath=$artifacts", "-p:RestorePackagesPath=$env:NUGET_PACKAGES", "-p:RestoreAdditionalProjectSources=$directory", "-p:PackageUnderTestVersion=$version", '-p:Configuration=Release')
                    try { Invoke-Dotnet (@('restore',$target,'--force') + $properties) } catch { throw "Candidate restore failed; check Package Source Mapping/private feeds. $($_.Exception.Message)" }
                    Assert-LocalPackages $artifacts $directory $env:NUGET_PACKAGES $version
                    Invoke-Tests $target ($properties + @('--no-restore'))
                }
                $actual = @(Get-Packages $directory $version)
                $saved = @(Get-Content (Join-Path $directory 'manifest.json') -Raw | ConvertFrom-Json)
                if (($actual | ConvertTo-Json -Compress) -cne ($saved | ConvertTo-Json -Compress)) { throw 'Integration tests changed candidate packages.' }
            }
        } finally { $env:NUGET_PACKAGES = $cache; Pop-Location }
        return
    }
    if ($Phase -eq 'publish' -and !$env:NG_API_KEY) { throw 'OIDC login did not return an API key.' }
    $actual = @(Get-Packages $directory $version)
    $saved = @(Get-Content (Join-Path $directory 'manifest.json') -Raw | ConvertFrom-Json)
    if (($actual | ConvertTo-Json -Compress) -cne ($saved | ConvertTo-Json -Compress)) { throw 'Packages changed after packing.' }
    if ($Phase -eq 'release') {
        if ($env:GITHUB_REF_TYPE -ne 'tag' -or $version -cne (Get-Version '' $env:GITHUB_REF_NAME)) { throw 'Release version must match its tag.' }
        $tag = $env:GITHUB_REF_NAME; $repo = $env:GITHUB_REPOSITORY
        Assert-NewRelease
        $args = @('release','create',$tag,'--repo',$repo,'--verify-tag','--draft','--title',$tag,'--notes',"NuGet packages $version.")
        if ($version.Contains('-')) { $args += '--prerelease' }
        & gh @args | Out-Host
        if ($LASTEXITCODE) { throw 'Could not create GitHub draft release.' }
        $files = @($actual | ForEach-Object { Join-Path $directory $_.File }) + @(Join-Path $directory 'manifest.json')
        & gh release upload $tag @files --repo $repo | Out-Host
        if ($LASTEXITCODE) { throw 'Could not upload release assets; the release remains a draft. Follow README recovery guidance.' }
        & gh release edit $tag --repo $repo --draft=false | Out-Host
        if ($LASTEXITCODE) { throw 'Could not publish the completed draft release. Follow README recovery guidance.' }
        return
    }
    foreach ($package in $actual | Where-Object File -like '*.nupkg') {
        Invoke-Dotnet @('nuget','push',(Join-Path $directory $package.File),'--api-key',$env:NG_API_KEY,'--source','https://api.nuget.org/v3/index.json')
    }
}

if ($Phase) {
    if ($env:NG_INPUTS) {
        $inputs = $env:NG_INPUTS | ConvertFrom-Json -AsHashtable
        foreach ($pair in @{ STAGES='stages'; ROOT='working-directory'; VERSION='version'; TEST='test-target'; INTEGRATION='integration-target'; PACK='pack-target' }.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable("NG_$($pair.Key)", $inputs[$pair.Value])
        }
    }
    Invoke-Pipeline $Phase
}