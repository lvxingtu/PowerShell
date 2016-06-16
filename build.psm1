# Use the .NET Core APIs to determine the current platform; if a runtime
# exception is thrown, we are on FullCLR, not .NET Core.
try {
    $Runtime = [System.Runtime.InteropServices.RuntimeInformation]
    $OSPlatform = [System.Runtime.InteropServices.OSPlatform]

    $IsCore = $true
    $IsLinux = $Runtime::IsOSPlatform($OSPlatform::Linux)
    $IsOSX = $Runtime::IsOSPlatform($OSPlatform::OSX)
    $IsWindows = $Runtime::IsOSPlatform($OSPlatform::Windows)
} catch {
    # If these are already set, then they're read-only and we're done
    try {
        $IsCore = $false
        $IsLinux = $false
        $IsOSX = $false
        $IsWindows = $true
    }
    catch { }
}


function Start-PSBuild {
    [CmdletBinding(DefaultParameterSetName='CoreCLR')]
    param(
        [switch]$NoPath,
        [switch]$Restore,
        [string]$Output,
        [switch]$ResGen,

        [Parameter(ParameterSetName='CoreCLR')]
        [switch]$Publish,

        # These runtimes must match those in project.json
        # We do not use ValidateScript since we want tab completion
        [ValidateSet("ubuntu.14.04-x64",
                     "debian.8-x64",
                     "centos.7.1-x64",
                     "win7-x64",
                     "win81-x64",
                     "win10-x64",
                     "osx.10.11-x64")]
        [Parameter(ParameterSetName='CoreCLR')]
        [string]$Runtime,

        [Parameter(ParameterSetName='FullCLR')]
        [switch]$FullCLR,

        [Parameter(ParameterSetName='FullCLR')]
        [string]$cmakeGenerator = "Visual Studio 14 2015 Win64",

        [Parameter(ParameterSetName='FullCLR')]
        [ValidateSet("Debug",
                     "Release")]
        [string]$msbuildConfiguration = "Release"
    )

    # save Git description to file for PowerShell to include in PSVersionTable
    git --git-dir="$PSScriptRoot/.git" describe --dirty --abbrev=60 > "$psscriptroot/powershell.version"

    # simplify ParameterSetNames
    if ($PSCmdlet.ParameterSetName -eq 'FullCLR') {
        $FullCLR = $true
    }

    if (-not $NoPath) {
        Write-Verbose "Appending probable .NET CLI tool path"
        if ($IsWindows) {
            $env:Path += ";$env:LocalAppData\Microsoft\dotnet"
        } else {
            $env:PATH += ":$env:HOME/.dotnet"
        }
    }

    if ($IsWindows) {
        # use custom package store - this value is also defined in nuget.config under config/repositoryPath
        # dotnet restore uses this value as the target for installing the assemblies for referenced nuget packages.
        # dotnet build does not currently consume the  config value but will consume env:NUGET_PACKAGES to resolve these dependencies
        $env:NUGET_PACKAGES="$PSScriptRoot\Packages"
    }

    # verify we have all tools in place to do the build
    $precheck = precheck 'dotnet' "Build dependency 'dotnet' not found in PATH! See: https://dotnet.github.io/getting-started/"
    if ($FullCLR) {
        # cmake is needed to build powershell.exe
        $precheck = $precheck -and (precheck 'cmake' 'cmake not found. You can install it from https://chocolatey.org/packages/cmake.portable')

        # msbuild is needed to build powershell.exe
        # msbuild is part of .NET Framework, we can try to get it from well-known location.
        if (-not $NoPath -and -not (Get-Command -Name msbuild -ErrorAction Ignore)) {
            Write-Verbose "Appending probable Visual C++ tools path"
            $env:path += ";${env:SystemRoot}\Microsoft.Net\Framework\v4.0.30319"
        }

        $precheck = $precheck -and (precheck 'msbuild' 'msbuild not found. Install Visual Studio 2015.')
    } elseif ($IsLinux -or $IsOSX) {
        $InstallCommand = if ($IsLinux) {
            'apt-get'
        } elseif ($IsOSX) {
            'brew'
        }

        foreach ($Dependency in 'cmake', 'make', 'g++') {
            $precheck = $precheck -and (precheck $Dependency "Build dependency '$Dependency' not found. Run '$InstallCommand install $Dependency'")
        }
    }

    # Abort if any precheck failed
    if (-not $precheck) {
        return
    }

    # set output options
    $OptionsArguments = @{Publish=$Publish; Output=$Output; FullCLR=$FullCLR; Runtime=$Runtime}
    $script:Options = New-PSOptions @OptionsArguments

    # setup arguments
    $Arguments = @()
    if ($Publish) {
        $Arguments += "publish"
    } else {
        $Arguments += "build"
    }
    if ($Output) {
        $Arguments += "--output", (Join-Path $PSScriptRoot $Output)
    }
    $Arguments += "--configuration", $Options.Configuration
    $Arguments += "--framework", $Options.Framework
    $Arguments += "--runtime", $Options.Runtime

    # handle Restore
    if ($Restore -or -not (Test-Path "$($Options.Top)/project.lock.json")) {
        log "Run dotnet restore"

        $RestoreArguments = @("--verbosity")
        if ($PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) {
            $RestoreArguments += "Info"
        } else {
            $RestoreArguments += "Warning"
        }

        $RestoreArguments += "$PSScriptRoot"

        Start-NativeExecution { dotnet restore $RestoreArguments }
    }

    # handle ResGen
    if ($ResGen -or -not (Test-Path "$($Options.Top)/gen"))
    {
        log "Run ResGen (generating C# bindings for resx files)"
        Start-ResGen
    }

    # Build native components
    if ($IsLinux -or $IsOSX) {
        $Ext = if ($IsLinux) {
            "so"
        } elseif ($IsOSX) {
            "dylib"
        }

        $Native = "$PSScriptRoot/src/libpsl-native"
        $Lib = "$($Options.Top)/libpsl-native.$Ext"
        log "Start building $Lib"

        try {
            Push-Location $Native
            cmake -DCMAKE_BUILD_TYPE=Debug .
            make -j
            make test
        } finally {
            Pop-Location
        }

        if (-not (Test-Path $Lib)) {
            throw "Compilation of $Lib failed"
        }
    } elseif ($FullCLR) {
        log "Start building native powershell.exe"

        try {
            Push-Location "$PSScriptRoot\src\powershell-native"

            if ($cmakeGenerator) {
                cmake -G $cmakeGenerator .
            } else {
                cmake .
            }

            Start-NativeExecution { msbuild powershell.vcxproj /p:Configuration=$msbuildConfiguration }

        } finally {
            Pop-Location
        }
    }

    try {
        # Relative paths do not work well if cwd is not changed to project
        Push-Location $Options.Top
        log "Run dotnet $Arguments from $pwd"
        Start-NativeExecution { dotnet $Arguments }
        log "PowerShell output: $($Options.Output)"
    } finally {
        Pop-Location
    }

}


function New-PSOptions {
    [CmdletBinding()]
    param(
        [ValidateSet("Linux", "Debug", "Release")]
        [string]$Configuration,

        [ValidateSet("netcoreapp1.0", "net451")]
        [string]$Framework,

        # These are duplicated from Start-PSBuild
        # We do not use ValidateScript since we want tab completion
        [ValidateSet("",
                     "ubuntu.14.04-x64",
                     "debian.8-x64",
                     "centos.7.1-x64",
                     "win7-x64",
                     "win81-x64",
                     "win10-x64",
                     "osx.10.11-x64")]
        [string]$Runtime,

        [switch]$Publish,
        [string]$Output,

        [switch]$FullCLR
    )

    if ($FullCLR) {
        $Top = "$PSScriptRoot/src/Microsoft.PowerShell.ConsoleHost"
    } else {
        $Top = "$PSScriptRoot/src/powershell"
    }
    Write-Verbose "Top project directory is $Top"

    if (-not $Configuration) {
        $Configuration = if ($IsLinux -or $IsOSX) {
            "Linux"
        } elseif ($IsWindows) {
            "Debug"
        }
        log "Using configuration '$Configuration'"
    }

    if (-not $Framework) {
        $Framework = if ($FullCLR) {
            "net451"
        } else {
            "netcoreapp1.0"
        }
        log "Using framework '$Framework'"
    }

    if (-not $Runtime) {
        $Runtime = dotnet --info | % {
            if ($_ -match "RID") {
                $_ -split "\s+" | Select-Object -Last 1
            }
        }

        if (-not $Runtime) {
            Throw "Could not determine Runtime Identifier, please update dotnet"
        } else {
            log "Using runtime '$Runtime'"
        }
    }

    $Executable = if ($IsLinux -or $IsOSX) {
        "powershell"
    } elseif ($IsWindows) {
        "powershell.exe"
    }

    # Build the Output path
    if ($Output) {
        $Output = Join-Path $PSScriptRoot $Output
    } else {
        $Output = [IO.Path]::Combine($Top, "bin", $Configuration, $Framework)

        # FullCLR only builds a library, so there is no runtime component
        if (-not $FullCLR) {
            $Output = [IO.Path]::Combine($Output, $Runtime)
        }

        # Publish injects the publish directory
        if ($Publish) {
            $Output = [IO.Path]::Combine($Output, "publish")
        }

        $Output = [IO.Path]::Combine($Output, $Executable)
    }

    return @{ Top = $Top;
              Configuration = $Configuration;
              Framework = $Framework;
              Runtime = $Runtime;
              Output = $Output }
}


function Get-PSOutput {
    [CmdletBinding()]param(
        [hashtable]$Options
    )
    if ($Options) {
        return $Options.Output
    } elseif ($script:Options) {
        return $script:Options.Output
    } else {
        return (New-PSOptions).Output
    }
}


function Start-PSPester {
    [CmdletBinding()]param(
        [string]$Flags = "-ExcludeTag 'Slow' -EnableExit -OutputFile pester-tests.xml -OutputFormat NUnitXml",
        [string]$Tests = "*",
        [ValidateScript({ Test-Path -PathType Container $_})]
        [string]$Directory = "$PSScriptRoot/test/powershell"
    )

    & (Get-PSOutput) -noprofile -c "Invoke-Pester $Flags $Directory/$Tests"
    if ($LASTEXITCODE -ne 0) {
        throw "$LASTEXITCODE Pester tests failed"
    }
}


function Start-PSxUnit {
    [CmdletBinding()]param()
    if ($IsWindows) {
        throw "xUnit tests are only currently supported on Linux / OS X"
    }

    if ($IsOSX) {
        log "Not yet supported on OS X, pretending they passed..."
        return
    }

    $Arguments = "--configuration", "Linux", "-parallel", "none"
    if ($PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) {
        $Arguments += "-verbose"
    }

    $Content = Split-Path -Parent (Get-PSOutput)
    if (-not (Test-Path $Content)) {
        throw "PowerShell must be built before running tests!"
    }

    try {
        Push-Location $PSScriptRoot/test/csharp
        # Path manipulation to obtain test project output directory
        $Output = Join-Path $pwd ((Split-Path -Parent (Get-PSOutput)) -replace (New-PSOptions).Top)
        Write-Verbose "Output is $Output"

        Copy-Item -ErrorAction SilentlyContinue -Recurse -Path $Content/* -Include Modules,libpsl-native* -Destination $Output
        Start-NativeExecution { dotnet test $Arguments }

        if ($LASTEXITCODE -ne 0) {
            throw "$LASTEXITCODE xUnit tests failed"
        }
    } finally {
        Pop-Location
    }
}


function Start-PSBootstrap {
    [CmdletBinding()]param(
        [ValidateSet("dev", "beta", "preview")]
        [string]$Channel = "preview",
        [string]$Version = "1.0.0-preview2-003067"
    )

    Write-Host "Installing Open PowerShell build dependencies"

    Push-Location $PSScriptRoot/tools

    try {
        # Install dependencies for Linux and OS X
        if ($IsLinux) {
            $IsUbuntu = Select-String "Ubuntu 14.04" /etc/os-release -Quiet
            precheck 'curl' "Bootstrap dependency 'curl' not found in PATH, please install!" > $null
            if ($IsUbuntu) {
                # Setup LLVM feed
                curl -s http://llvm.org/apt/llvm-snapshot.gpg.key | sudo apt-key add -
                echo "deb http://llvm.org/apt/trusty/ llvm-toolchain-trusty-3.6 main" | sudo tee /etc/apt/sources.list.d/llvm.list
                sudo apt-get update -qq

                # Install ours and .NET's dependencies
                sudo apt-get install -y -qq make g++ cmake libc6 libgcc1 libstdc++6 libcurl3 libgssapi-krb5-2 libicu52 liblldb-3.6 liblttng-ust0 libssl1.0.0 libunwind8 libuuid1 zlib1g clang-3.5
            } else {
                Write-Warning "This script only supports Ubuntu 14.04, you must install dependencies manually!"
            }
        } elseif ($IsOSX) {
            precheck 'brew' "Bootstrap dependency 'brew' not found, must install Homebrew! See http://brew.sh/"

            # Install ours and .NET's dependencies
            brew install cmake wget openssl
            brew link --force openssl
        }

        $obtainUrl = "https://raw.githubusercontent.com/dotnet/cli/rel/1.0.0/scripts/obtain"

        # Install for Linux and OS X
        if ($IsLinux -or $IsOSX) {
            # Uninstall all previous dotnet packages
            $uninstallScript = if ($IsUbuntu) {
                "dotnet-uninstall-debian-packages.sh"
            } elseif ($IsOSX) {
                "dotnet-uninstall-pkgs.sh"
            }

            if ($uninstallScript) {
                curl -s $obtainUrl/uninstall/$uninstallScript -o $uninstallScript
                chmod +x $uninstallScript
                sudo ./$uninstallScript
            } else {
                Write-Warning "This script only removes prior versions of dotnet for Ubuntu 14.04 and OS X"
            }

            # Install new dotnet 1.0.0 preview packages
            $installScript = "dotnet-install.sh"
            curl -s $obtainUrl/$installScript -o $installScript
            chmod +x $installScript
            bash ./$installScript -c $Channel -v $Version
        }

        # Install for Windows
        if ($IsWindows -and -not $IsCore) {
            Remove-Item -ErrorAction SilentlyContinue -Recurse -Force ~\AppData\Local\Microsoft\dotnet
            $installScript = "dotnet-install.ps1"
            Invoke-WebRequest -Uri $obtainUrl/$installScript -OutFile $installScript
            & ./$installScript -c $Channel -v $Version
        } elseif ($IsWindows) {
            Write-Warning "Start-PSBootstrap cannot be run in Core PowerShell on Windows (need Invoke-WebRequest!)"
        }
    } finally {
        Pop-Location
    }
}


function Start-PSPackage {
    [CmdletBinding()]param(
        # PowerShell packages use Semantic Versioning http://semver.org/
        [string]$Version,
        # Package iteration version (rarely changed)
        [int]$Iteration = 1,
        # Ubuntu, CentOS, and OS X packages are supported
        [ValidateSet("deb", "osxpkg", "rpm")]
        [string]$Type
    )

    $Description = @"
Open PowerShell on .NET Core
PowerShell is an open-source, cross-platform, scripting language and rich object shell.
Built upon .NET Core, it is also a C# REPL.
"@

    # Use Git tag if not given a version
    if (-not $Version) {
        $Version = (git --git-dir="$PSScriptRoot/.git" describe) -Replace '^v'
    }

    $Source = Split-Path -Parent (Get-PSOutput -Options (New-PSOptions -Publish))
    Write-Verbose "Packaging $Source"

    if ($IsWindows) {
        $msiPackagePath = New-MSIPackage -ProductSourcePath $Source -ProductVersion $Version -Verbose
        $appxPackagePath = New-AppxPackage -PackageVersion $Version -SourcePath $Source -AssetsPath "$PSScriptRoot\Assets" -Verbose

        $packages = @($msiPackagePath, $appxPackagePath)
        
        return $packages
    }

    if (-not (Get-Command "fpm" -ErrorAction SilentlyContinue)) {
        throw "Build dependency 'fpm' not found in PATH! See: https://github.com/jordansissel/fpm"
    }

    # Decide package output type
    if (-not $Type) {
        $Type = if ($IsLinux) { "deb" } elseif ($IsOSX) { "osxpkg" }
        Write-Warning "-Type was not specified, continuing with $Type"
    }

    # Follow the Filesystem Hierarchy Standard for Linux and OS X
    $Destination = if ($IsLinux) {
        "/opt/microsoft/powershell"
    } elseif ($IsOSX) {
        "/usr/local/microsoft/powershell"
    }

    # Destination for symlink to powershell executable
    $Link = if ($IsLinux) {
        "/usr/bin"
    } elseif ($IsOSX) {
        "/usr/local/bin"
    }

    New-Item -Force -ItemType SymbolicLink -Path /tmp/powershell -Target $Destination/powershell >$null

    # there is a weired bug in fpm
    # if the target of the powershell symlink exists, `fpm` aborts
    # with a `utime` error on OS X.
    # so we move it to make symlink broken
    $symlink_dest = "$Destination/powershell"
    $hack_dest = "./_fpm_symlink_hack_powershell"
    if ($IsOSX)
    {
        if (Test-Path $symlink_dest)
        {
            Write-Warning "Move $symlink_dest to $hack_dest (fpm utime bug)"
            Move-Item $symlink_dest $hack_dest
        }
    }

    # Change permissions for packaging
    chmod -R go=u $Source /tmp/powershell

    $libunwind = switch ($Type) {
        "deb" { "libunwind8" }
        "rpm" { "libunwind" }
    }

    $libicu = switch ($Type) {
        "deb" { "libicu52" }
        "rpm" { "libicu" }
    }


    $Arguments = @(
        "--force", "--verbose",
        "--name", "powershell",
        "--version", $Version,
        "--iteration", $Iteration,
        "--maintainer", "Andrew Schwartzmeyer <andschwa@microsoft.com>",
        "--vendor", "Microsoft <mageng@microsoft.com>",
        "--url", "https://github.com/PowerShell/PowerShell",
        "--license", "Unlicensed",
        "--description", $Description,
        "--category", "shells",
        "--rpm-os", "linux",
        "--depends", $libunwind,
        "--depends", $libicu,
        "--deb-build-depends", "dotnet",
        "--deb-build-depends", "cmake",
        "--deb-build-depends", "g++",
        "-t", $Type,
        "-s", "dir",
        "$Source/=$Destination/",
        "/tmp/powershell=$Link"
    )

    # Build package
    fpm $Arguments

    if ($IsOSX)
    {
        # this is continuation of a fpm hack for a weired bug
        if (Test-Path $hack_dest)
        {
            Write-Warning "Move $hack_dest to $symlink_dest (fpm utime bug)"
            Move-Item $hack_dest $symlink_dest
        }
    }
}

function Publish-NuGetFeed
{
    param(
        [string]$OutputPath = "$PSScriptRoot/nuget-artifacts",
        [Parameter(Mandatory=$true)]
        [string]$VersionSuffix
    )

    @(
'Microsoft.PowerShell.Commands.Management',
'Microsoft.PowerShell.Commands.Utility',
'Microsoft.PowerShell.ConsoleHost',
'Microsoft.PowerShell.PSReadLine',
'Microsoft.PowerShell.Security',
'System.Management.Automation'
    ) | % {
        if ($VersionSuffix)
        {
            dotnet pack "src/$_" --output $OutputPath --version-suffix $VersionSuffix
        }
        else
        {
            dotnet pack "src/$_" --output $OutputPath
        }
    }
}


function Start-DevPSGitHub {
    param(
        [switch]$ZapDisable,
        [string[]]$ArgumentList = '',
        [switch]$LoadProfile,
        [string]$binDir = "$PSScriptRoot\src\Microsoft.PowerShell.ConsoleHost\bin\Debug\net451",
        [switch]$NoNewWindow
    )

    try {
        if ($LoadProfile -eq $false) {
            $ArgumentList = @('-noprofile') + $ArgumentList
        }

        $env:DEVPATH = $binDir
        if ($ZapDisable) {
            $env:COMPLUS_ZapDisable = 1
        }

        if (-not (Test-Path $binDir\powershell.exe.config)) {
            $configContents = @"
<?xml version="1.0" encoding="utf-8" ?>
<configuration>
<runtime>
<developmentMode developerInstallation="true"/>
</runtime>
</configuration>
"@
            $configContents | Out-File -Encoding Ascii $binDir\powershell.exe.config
        }

        # splatting for the win
        $startProcessArgs = @{
            FilePath = "$binDir\powershell.exe"
            ArgumentList = "$ArgumentList"
        }

        if ($NoNewWindow) {
            $startProcessArgs.NoNewWindow = $true
            $startProcessArgs.Wait = $true
        }

        Start-Process @startProcessArgs
    } finally {
        ri env:DEVPATH
        if ($ZapDisable) {
            ri env:COMPLUS_ZapDisable
        }
    }
}


<#
.EXAMPLE 
PS C:> Copy-MappedFiles -PslMonadRoot .\src\monad

copy files FROM .\src\monad (old location of submodule) TO src/<project> folders
#>
function Copy-MappedFiles {

    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true)]
        [string[]]$Path = "$PSScriptRoot",
        [Parameter(Mandatory=$true)]
        [string]$PslMonadRoot,
        [switch]$Force
    )

    begin 
    {
        function MaybeTerminatingWarning
        {
            param([string]$Message)

            if ($Force)
            {
                Write-Warning "$Message : ignoring (-Force)"
            }
            else
            {
                throw "$Message : use -Force to ignore"
            }
        }

        if (-not (Test-Path -PathType Container $PslMonadRoot))
        {
            throw "$pslMonadRoot is not a valid folder"
        }

        # Do some intelligens to prevent shouting us in the foot with CL management

        # finding base-line CL
        $cl = git --git-dir="$PSScriptRoot/.git" tag | % {if ($_ -match 'SD.(\d+)$') {[int]$Matches[1]} } | Sort-Object -Descending | Select-Object -First 1
        if ($cl)
        {
            Write-Host -ForegroundColor Green "Current base-line CL is SD:$cl (based on tags)"
        }
        else 
        {
            MaybeTerminatingWarning "Could not determine base-line CL based on tags"
        }

        try
        {
            Push-Location $PslMonadRoot
            if (git status --porcelain)
            {
                MaybeTerminatingWarning "$pslMonadRoot has changes"
            }

            if (git log --grep="SD:$cl" HEAD^..HEAD)
            {
                Write-Host -ForegroundColor Green "$pslMonadRoot HEAD matches [SD:$cl]"
            }
            else 
            {
                Write-Host -ForegroundColor Yellow "Try to checkout this commit in $pslMonadRoot :" 
                git log --grep="SD:$cl"

                MaybeTerminatingWarning "$pslMonadRoot HEAD doesn't match [SD:$cl]"
            }
        }
        finally
        {
            Pop-Location
        }

        $map = @{}
    }

    process
    {
        $map += Get-Mappings $Path -Root $PslMonadRoot
    }

    end
    {
        $map.GetEnumerator() | % {
            New-Item -ItemType Directory (Split-Path $_.Value) -ErrorAction SilentlyContinue > $null

            if ($PSBoundParameters['Verbose'])
            {
                Copy-Item $_.Key $_.Value -Verbose
            }
            else
            {
                Copy-Item $_.Key $_.Value
            }
        }
    }
}

function Get-Mappings
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true)]
        [string[]]$Path = "$PSScriptRoot",
        [string]$Root,
        [switch]$KeepRelativePaths
    )

    begin 
    {
        $mapFiles = @()
    }

    process
    {
        Write-Verbose "Discovering map files in $Path"
        $count = $mapFiles.Count

        if (-not (Test-Path $Path)) 
        {
            throw "Mapping file not found in $mappingFilePath"
        }

        if (Test-Path -PathType Container $Path)
        {
            $mapFiles += Get-ChildItem -Recurse $Path -Filter 'map.json' -File
        }
        else 
        {
            # it exists and it's a file, don't check the name pattern
            $mapFiles += Get-ChildItem $Path
        }

        Write-Verbose "Found $($mapFiles.Count - $count) map files in $Path"
    }

    end
    {
        $map = @{}
        $mapFiles | % {
            $rawHashtable = $_ | Get-Content -Raw | ConvertFrom-Json | Convert-PSObjectToHashtable
            $mapRoot = Split-Path $_.FullName
            if ($KeepRelativePaths) 
            {
                # not very elegant way to find relative for the current directory path
                $mapRoot = $mapRoot.Substring($PSScriptRoot.Length + 1)
                # keep original unix-style paths for git
                $mapRoot = $mapRoot.Replace('\', '/')
            }

            $rawHashtable.GetEnumerator() | % {
                $newKey = if ($Root) { Join-Path $Root $_.Key } else { $_.Key }
                $newValue = if ($KeepRelativePaths) { ($mapRoot + '/' + $_.Value) } else { Join-Path $mapRoot $_.Value } 
                $map[$newKey] = $newValue
            }
        }

        return $map
    }
}


<#
.EXAMPLE Send-GitDiffToSd -diffArg1 32b90c048aa0c5bc8e67f96a98ea01c728c4a5be~1 -diffArg2 32b90c048aa0c5bc8e67f96a98ea01c728c4a5be -AdminRoot d:\e\ps_dev\admin
Apply a signle commit to admin folder
#>
function Send-GitDiffToSd {
    param(
        [Parameter(Mandatory)]
        [string]$diffArg1,
        [Parameter(Mandatory)]
        [string]$diffArg2,
        [Parameter(Mandatory)]
        [string]$AdminRoot,
        [switch]$WhatIf
    )

    # this is only for windows, because you cannot have SD enlistment on Linux
    $patchPath = (ls (Join-Path (get-command git).Source '..\..') -Recurse -Filter 'patch.exe').FullName
    $m = Get-Mappings -KeepRelativePaths -Root $AdminRoot
    $affectedFiles = git diff --name-only $diffArg1 $diffArg2
    $affectedFiles | % {
        Write-Host -Foreground Green "Changes in file $_"
    }

    $rev = Get-InvertedOrderedMap $m
    foreach ($file in $affectedFiles) {
        if ($rev.Contains) {
            $sdFilePath = $rev[$file]
            if (-not $sdFilePath)
            {
                Write-Warning "Cannot find mapped file for $file, skipping"
                continue
            }

            $diff = git diff $diffArg1 $diffArg2 -- $file
            if ($diff) {
                Write-Host -Foreground Green "Apply patch to $sdFilePath"
                Set-Content -Value $diff -Path $env:TEMP\diff -Encoding Ascii
                if ($WhatIf) {
                    Write-Host -Foreground Green "Patch content"
                    Get-Content $env:TEMP\diff
                } else {
                    & $patchPath --binary -p1 $sdFilePath $env:TEMP\diff
                }
            } else {
                Write-Host -Foreground Green "No changes in $file"
            }
        } else {
            Write-Host -Foreground Green "Ignore changes in $file, because there is no mapping for it"
        }
    }
}

function Start-ResGen
{
    [CmdletBinding()]
    param()

    @("Microsoft.PowerShell.Commands.Management",
"Microsoft.PowerShell.Commands.Utility",
"Microsoft.PowerShell.ConsoleHost",
"Microsoft.PowerShell.CoreCLR.Eventing",
"Microsoft.PowerShell.LocalAccounts",
"Microsoft.PowerShell.Security",
"System.Management.Automation") | % {
        $module = $_
        Get-ChildItem "$PSScriptRoot/src/$module/resources" | % {
            $className = $_.Name.Replace('.resx', '')
            $xml = [xml](Get-Content -raw $_.FullName)

            $fileName = $className
            $namespace = ''

            $lastIndexOfDot = $className.LastIndexOf(".")
            if ($lastIndexOfDot -ne -1)
            {
                $namespace = $className.Substring(0, $lastIndexOfDot)
                $className = $className.Substring($lastIndexOfDot + 1)
            }

            $genSource = Get-StronglyTypeCsFileForResx -xml $xml -ModuleName $module -ClassName $className -NamespaceName $namespace
            $outPath = "$PSScriptRoot/src/$module/gen/$fileName.cs"
            Write-Verbose "ResGen for $outPath"
            New-Item -Type Directory -ErrorAction SilentlyContinue (Split-Path $outPath) > $null
            Set-Content -Encoding Ascii -Path $outPath -Value $genSource
        }
    }
}


function script:log([string]$message) {
    Write-Host -Foreground Green $message
}


function script:precheck([string]$command, [string]$missedMessage) {
    $c = Get-Command $command -ErrorAction SilentlyContinue
    if (-not $c) {
        Write-Warning $missedMessage
        return $false
    } else {
        return $true
    }
}


function script:Get-InvertedOrderedMap {
    param(
        $h
    )
    $res = [ordered]@{}
    foreach ($q in $h.GetEnumerator()) {
        if ($res.Contains($q.Value)) {
            throw "Cannot invert hashtable: duplicated key $($q.Value)"
        }

        $res[$q.Value] = $q.Key
    }
    return $res
}


## this function is from Dave Wyatt's answer on
## http://stackoverflow.com/questions/22002748/hashtables-from-convertfrom-json-have-different-type-from-powershells-built-in-h
function script:Convert-PSObjectToHashtable {
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )

    process {
        if ($null -eq $InputObject) { return $null }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @(
                foreach ($object in $InputObject) { Convert-PSObjectToHashtable $object }
            )

            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject]) {
            $hash = @{}

            foreach ($property in $InputObject.PSObject.Properties)
            {
                $hash[$property.Name] = Convert-PSObjectToHashtable $property.Value
            }

            $hash
        } else {
            $InputObject
        }
    }
}

# this function wraps native command Execution
# for more information, read https://mnaoumov.wordpress.com/2015/01/11/execution-of-external-commands-in-powershell-done-right/
function script:Start-NativeExecution([scriptblock]$sb)
{
    $backupEAP = $script:ErrorActionPreference
    $script:ErrorActionPreference = "Continue"
    try
    {
        & $sb
        # note, if $sb doens't have a native invokation, $LASTEXITCODE will
        # point to the obsolete value
        if ($LASTEXITCODE -ne 0)
        {
            throw "Execution of {$sb} failed with exit code $LASTEXITCODE"
        }
    }
    finally
    {
        $script:ErrorActionPreference = $backupEAP
    }
}

function script:Get-StronglyTypeCsFileForResx
{
    param($xml, $ModuleName, $ClassName, $NamespaceName = '')

$banner = @'
//------------------------------------------------------------------------------
// <auto-generated>
//     This code was generated by a Start-ResGen funciton from build.psm1.
//     To add or remove a member, edit your .ResX file then rerun Start-ResGen.
//
//     Changes to this file may cause incorrect behavior and will be lost if
//     the code is regenerated.
// </auto-generated>
//------------------------------------------------------------------------------

{0}
'@

$namespace = @'
namespace {0} {{
{1}
}}
'@

$body = @'
using System;
using System.Reflection;

/// <summary>
///   A strongly-typed resource class, for looking up localized strings, etc.
/// </summary>
[global::System.CodeDom.Compiler.GeneratedCodeAttribute("System.Resources.Tools.StronglyTypedResourceBuilder", "4.0.0.0")]
[global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
[global::System.Runtime.CompilerServices.CompilerGeneratedAttribute()]

internal class {0} {{

    private static global::System.Resources.ResourceManager resourceMan;

    private static global::System.Globalization.CultureInfo resourceCulture;

    [global::System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("Microsoft.Performance", "CA1811:AvoidUncalledPrivateCode")]
    internal {0}() {{
    }}

    /// <summary>
    ///   Returns the cached ResourceManager instance used by this class.
    /// </summary>
    [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Advanced)]
    internal static global::System.Resources.ResourceManager ResourceManager {{
        get {{
            if (object.ReferenceEquals(resourceMan, null)) {{
                global::System.Resources.ResourceManager temp = new global::System.Resources.ResourceManager("{1}.resources.{0}", typeof({0}).GetTypeInfo().Assembly);
                resourceMan = temp;
            }}
            return resourceMan;
        }}
    }}

    /// <summary>
    ///   Overrides the current thread's CurrentUICulture property for all
    ///   resource lookups using this strongly typed resource class.
    /// </summary>
    [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Advanced)]
    internal static global::System.Globalization.CultureInfo Culture {{
        get {{
            return resourceCulture;
        }}
        set {{
            resourceCulture = value;
        }}
    }}
    {2}
}}
'@

    $entry = @'

    /// <summary>
    ///   Looks up a localized string similar to {1}
    /// </summary>
    internal static string {0} {{
        get {{
            return ResourceManager.GetString("{0}", resourceCulture);
        }}
    }}
'@
    $entries = $xml.root.data | % {
        if ($_) {
            $val = $_.value.Replace("`n", "`n    ///")
            $name = $_.name.Replace(' ', '_')
            $entry -f $name,$val
        }
    } | Out-String
    
    $bodyCode = $body -f $ClassName,$ModuleName,$entries

    if ($NamespaceName -ne '')
    {
        $bodyCode = $namespace -f $NamespaceName, $bodyCode
    }

    $resultCode = $banner -f $bodyCode

    return $resultCode -replace "`r`n?|`n","`r`n"
}

function New-MSIPackage
{
    [CmdletBinding()]
    param (
    
        # Name of the Product
        [ValidateNotNullOrEmpty()]
        [string] $ProductName = 'OpenPowerShell', 

        # Version of the Product
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ProductVersion,

        # Product Guid needs to change for every version to support SxS install
        [ValidateNotNullOrEmpty()]
        [string] $ProductGuid = 'a5249933-73a1-4b10-8a4c-13c98bdc16fe',

        # Source Path to the Product Files - required to package the contents into an MSI
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ProductSourcePath,

        # File describing the MSI Package creation semantics
        [ValidateNotNullOrEmpty()]
        [string] $ProductWxsPath = (Join-Path $pwd '\assets\Product.wxs')

    )    

    $wixToolsetBinPath = "${env:ProgramFiles(x86)}\WiX Toolset v3.10\bin"

    Write-Verbose "Ensure Wix Toolset is present on the machine @ $wixToolsetBinPath"
    if (-not (Test-Path $wixToolsetBinPath))
    {
        throw "Install Wix Toolset prior to running this script - https://wix.codeplex.com/downloads/get/1540240"
    }

    Write-Verbose "Initialize Wix executables - Heat.exe, Candle.exe, Light.exe"
    $wixHeatExePath = Join-Path $wixToolsetBinPath "Heat.exe"
    $wixCandleExePath = Join-Path $wixToolsetBinPath "Candle.exe"
    $wixLightExePath = Join-Path $wixToolsetBinPath "Light.exe"
    
    # Wix tooling does not like hyphen in the foldername
    $ProductVersion = $ProductVersion.Replace('-', '_')

    $productVersionWithName = $ProductName + "_" + $ProductVersion
    Write-Verbose "Create MSI for Product $productVersionWithName"

    [Environment]::SetEnvironmentVariable("ProductSourcePath", $ProductSourcePath, "Process")
    [Environment]::SetEnvironmentVariable("ProductName", $ProductName, "Process")
    [Environment]::SetEnvironmentVariable("ProductGuid", $ProductGuid, "Process")
    [Environment]::SetEnvironmentVariable("ProductVersion", $ProductVersion, "Process")
    [Environment]::SetEnvironmentVariable("ProductVersionWithName", $productVersionWithName, "Process")

    $wixFragmentPath = (Join-path $env:Temp "Fragment.wxs")
    $wixObjProductPath = (Join-path $env:Temp "Product.wixobj")
    $wixObjFragmentPath = (Join-path $env:Temp "Fragment.wixobj")
    
    $msiLocationPath = Join-Path $pwd "$productVersionWithName.msi"    
    Remove-Item -ErrorAction SilentlyContinue $msiLocationPath -Force

    & $wixHeatExePath dir  $ProductSourcePath -dr  $productVersionWithName -cg $productVersionWithName -gg -sfrag -srd -scom -sreg -out $wixFragmentPath -var env.ProductSourcePath -v | Write-Verbose
    & $wixCandleExePath  "$ProductWxsPath"  "$wixFragmentPath" -out (Join-Path "$env:Temp" "\\") -arch x64 -v | Write-Verbose
    & $wixLightExePath -out "$productVersionWithName.msi" $wixObjProductPath $wixObjFragmentPath -ext WixUIExtension -v | Write-Verbose
    
    Remove-Item -ErrorAction SilentlyContinue *.wixpdb -Force

    Write-Verbose "You can find the MSI @ $msiLocationPath"
    return $msiLocationPath
}

# Function to create an Appx package compatible with Windows 8.1 and above
function New-AppxPackage
{
    [CmdletBinding()]
    param (
    
        # Name of the Package
        [ValidateNotNullOrEmpty()]
        [string] $PackageName = 'OpenPowerShell', 

        # Version of the Package
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageVersion,        

        # Source Path to the Binplaced Files
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePath,

        # Path to Assets folder containing Appx specific artifacts
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $AssetsPath        
    )
    
    Write-Verbose "Extract the version in the form of a.b.c.d for $PackageVersion"
    $PackageVersionTokens = $PackageVersion.Split('-')
    $PackageVersion = ([regex]::matches($PackageVersion, "\d+(\.\d+)+"))[0].value

    # Need to add the last version field for makeappx
    $PackageVersion = $PackageVersion + '.' + $PackageVersionTokens[1]
    Write-Verbose "Package Version is $PackageVersion"

    $win10sdkBinPath = "${env:ProgramFiles(x86)}\Windows Kits\10\bin\x64"

    Write-Verbose "Ensure Win10 SDK is present on the machine @ $win10sdkBinPath"
    if (-not (Test-Path $win10sdkBinPath))
    {
        throw "Install Win10 SDK prior to running this script - https://go.microsoft.com/fwlink/p/?LinkID=698771"
    }

    Write-Verbose "Ensure Source Path is valid - $SourcePath"
    if (-not (Test-Path $SourcePath))
    {
        throw "Invalid SourcePath - $SourcePath"
    }

    Write-Verbose "Ensure Assets Path is valid - $AssetsPath"
    if (-not (Test-Path $AssetsPath))
    {
        throw "Invalid AssetsPath - $AssetsPath"
    }
    
    Write-Verbose "Initialize MakeAppx executable path"
    $makeappxExePath = Join-Path $win10sdkBinPath "MakeAppx.exe"

    $appxManifest = @"
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
  <Identity Name="Microsoft.OpenPowerShell" ProcessorArchitecture="x64" Publisher="CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" Version="#VERSION#" />
  <Properties>
    <DisplayName>OpenPowerShell</DisplayName>
    <PublisherDisplayName>Microsoft Corporation</PublisherDisplayName>
    <Logo>#LOGO#</Logo>
  </Properties>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.14257.0" MaxVersionTested="12.0.0.0" />
    <TargetDeviceFamily Name="Windows.Server" MinVersion="10.0.14257.0" MaxVersionTested="12.0.0.0" />
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
  <Applications>
    <Application Id="OpenPowerShell" Executable="powershell.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="OpenPowerShell" Description="OpenPowerShell Package" BackgroundColor="transparent" Square150x150Logo="#SQUARE150x150LOGO#" Square44x44Logo="#SQUARE44x44LOGO#">
      </uap:VisualElements>
    </Application>
  </Applications>
</Package>
"@

    $appxManifest = $appxManifest.Replace('#VERSION#', $PackageVersion)
    $appxManifest = $appxManifest.Replace('#LOGO#', 'Assets\Powershell_256.png')
    $appxManifest = $appxManifest.Replace('#SQUARE150x150LOGO#', 'Assets\Powershell_256.png')
    $appxManifest = $appxManifest.Replace('#SQUARE44x44LOGO#', 'Assets\Powershell_48.png')

    Write-Verbose "Place Appx Manifest in $SourcePath"
    $appxManifest | Out-File "$SourcePath\AppxManifest.xml" -Force
    
    $assetsInSourcePath = "$SourcePath" + '\Assets'
    New-Item $assetsInSourcePath -type directory -Force | Out-Null

    $assetsInSourcePath = Join-Path $SourcePath 'Assets'

    Write-Verbose "Place AppxManifest dependencies such as images to $assetsInSourcePath" 
    Copy-Item "$AssetsPath\*.png" $assetsInSourcePath -Force
    
    $appxPackageName = $PackageName + "_" + $PackageVersion
    $appxPackagePath = "$pwd\$appxPackageName.appx"
    Write-Verbose "Calling MakeAppx from $makeappxExePath to create the package @ $appxPackagePath"
    & $makeappxExePath pack /o /v /d $SourcePath  /p $appxPackagePath | Write-Verbose

    Write-Verbose "Clean-up Appx artifacts and Assets from $SourcePath"    
    Remove-Item $assetsInSourcePath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$SourcePath\AppxManifest.xml" -Force -ErrorAction SilentlyContinue

    return $appxPackagePath
}