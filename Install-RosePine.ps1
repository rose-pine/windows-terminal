[CmdletBinding()]
param(
    [ValidateSet('Auto', 'RosePine', 'Moon', 'Dawn')]
    [string]$Variant = 'Auto',

    [string]$SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$variantDetails = @{
    RosePine = @{ Name = 'rose-pine'; Scheme = 'rose-pine.scheme.json'; Theme = 'rose-pine.theme.json' }
    Moon = @{ Name = 'rose-pine-moon'; Scheme = 'rose-pine-moon.scheme.json'; Theme = 'rose-pine-moon.theme.json' }
    Dawn = @{ Name = 'rose-pine-dawn'; Scheme = 'rose-pine-dawn.scheme.json'; Theme = 'rose-pine-dawn.theme.json' }
}

$installPlans = @{
    Auto = @{ Variants = @('RosePine', 'Dawn'); Dark = 'rose-pine'; Light = 'rose-pine-dawn' }
    RosePine = @{ Variants = @('RosePine'); Dark = 'rose-pine'; Light = 'rose-pine' }
    Moon = @{ Variants = @('Moon'); Dark = 'rose-pine-moon'; Light = 'rose-pine-moon' }
    Dawn = @{ Variants = @('Dawn'); Dark = 'rose-pine-dawn'; Light = 'rose-pine-dawn' }
}

function Fail([string]$Message) {
    throw [System.InvalidOperationException]::new($Message)
}

function Skip-JsoncTrivia([string]$Text, [int]$Index) {
    while ($Index -lt $Text.Length) {
        if ([char]::IsWhiteSpace($Text[$Index])) {
            $Index++
            continue
        }
        if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq '/' -and $Text[$Index + 1] -eq '/') {
            $Index += 2
            while ($Index -lt $Text.Length -and $Text[$Index] -ne "`n" -and $Text[$Index] -ne "`r") { $Index++ }
            continue
        }
        if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq '/' -and $Text[$Index + 1] -eq '*') {
            $Index += 2
            while ($Index + 1 -lt $Text.Length -and -not ($Text[$Index] -eq '*' -and $Text[$Index + 1] -eq '/')) { $Index++ }
            if ($Index + 1 -ge $Text.Length) { Fail 'Unterminated block comment in settings.json.' }
            $Index += 2
            continue
        }
        break
    }
    return $Index
}

function Get-JsonStringEnd([string]$Text, [int]$Index) {
    if ($Index -ge $Text.Length -or $Text[$Index] -ne '"') { Fail 'Expected a JSON string.' }
    $Index++
    while ($Index -lt $Text.Length) {
        if ($Text[$Index] -eq '\') {
            $Index += 2
            continue
        }
        if ($Text[$Index] -eq '"') { return $Index + 1 }
        $Index++
    }
    Fail 'Unterminated JSON string in settings.json.'
}

function Get-JsonValueEnd([string]$Text, [int]$Index) {
    if ($Index -ge $Text.Length) { Fail 'Expected a JSON value.' }
    if ($Text[$Index] -eq '"') { return Get-JsonStringEnd $Text $Index }

    if ($Text[$Index] -eq '{' -or $Text[$Index] -eq '[') {
        $opening = $Text[$Index]
        $closing = if ($opening -eq '{') { '}' } else { ']' }
        $depth = 1
        $Index++
        while ($Index -lt $Text.Length) {
            if ($Text[$Index] -eq '"') {
                $Index = Get-JsonStringEnd $Text $Index
                continue
            }
            if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq '/' -and $Text[$Index + 1] -eq '/') {
                $Index += 2
                while ($Index -lt $Text.Length -and $Text[$Index] -ne "`n" -and $Text[$Index] -ne "`r") { $Index++ }
                continue
            }
            if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq '/' -and $Text[$Index + 1] -eq '*') {
                $Index += 2
                while ($Index + 1 -lt $Text.Length -and -not ($Text[$Index] -eq '*' -and $Text[$Index + 1] -eq '/')) { $Index++ }
                if ($Index + 1 -ge $Text.Length) { Fail 'Unterminated block comment in settings.json.' }
                $Index += 2
                continue
            }
            if ($Text[$Index] -eq $opening) { $depth++ }
            if ($Text[$Index] -eq $closing) {
                $depth--
                if ($depth -eq 0) { return $Index + 1 }
            }
            $Index++
        }
        Fail 'Unterminated JSON container in settings.json.'
    }

    while ($Index -lt $Text.Length -and $Text[$Index] -notin @(',', '}', ']', "`r", "`n", ' ', "`t")) { $Index++ }
    return $Index
}

function Get-JsonStringValue([string]$Text, [int]$Start, [int]$End) {
    try {
        return ($Text.Substring($Start, $End - $Start) | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Fail "Invalid JSON string in settings.json: $($_.Exception.Message)"
    }
}

function Get-ObjectLayout([string]$Text, [int]$Start) {
    if ($Start -ge $Text.Length -or $Text[$Start] -ne '{') { Fail 'Expected a JSON object.' }
    $properties = [System.Collections.Generic.List[object]]::new()
    $Index = Skip-JsoncTrivia $Text ($Start + 1)
    while ($Index -lt $Text.Length -and $Text[$Index] -ne '}') {
        $keyStart = $Index
        $keyEnd = Get-JsonStringEnd $Text $keyStart
        $key = Get-JsonStringValue $Text $keyStart $keyEnd
        $Index = Skip-JsoncTrivia $Text $keyEnd
        if ($Index -ge $Text.Length -or $Text[$Index] -ne ':') { Fail "Expected ':' after '$key'." }
        $valueStart = Skip-JsoncTrivia $Text ($Index + 1)
        $valueEnd = Get-JsonValueEnd $Text $valueStart
        $properties.Add([pscustomobject]@{ Name = $key; KeyStart = $keyStart; ValueStart = $valueStart; ValueEnd = $valueEnd })
        $Index = Skip-JsoncTrivia $Text $valueEnd
        if ($Index -lt $Text.Length -and $Text[$Index] -eq ',') {
            $Index = Skip-JsoncTrivia $Text ($Index + 1)
            continue
        }
        if ($Index -lt $Text.Length -and $Text[$Index] -eq '}') { break }
        Fail "Expected ',' or '}' after '$key'."
    }
    if ($Index -ge $Text.Length) { Fail 'Unterminated JSON object in settings.json.' }
    return [pscustomobject]@{ Properties = $properties; Close = $Index }
}

function Get-ArrayLayout([string]$Text, [int]$Start) {
    if ($Start -ge $Text.Length -or $Text[$Start] -ne '[') { Fail 'Expected a JSON array.' }
    $values = [System.Collections.Generic.List[object]]::new()
    $Index = Skip-JsoncTrivia $Text ($Start + 1)
    while ($Index -lt $Text.Length -and $Text[$Index] -ne ']') {
        $valueStart = $Index
        $valueEnd = Get-JsonValueEnd $Text $valueStart
        $values.Add([pscustomobject]@{ Start = $valueStart; End = $valueEnd })
        $Index = Skip-JsoncTrivia $Text $valueEnd
        if ($Index -lt $Text.Length -and $Text[$Index] -eq ',') {
            $Index = Skip-JsoncTrivia $Text ($Index + 1)
            continue
        }
        if ($Index -lt $Text.Length -and $Text[$Index] -eq ']') { break }
        Fail "Expected ',' or ']' in an array."
    }
    if ($Index -ge $Text.Length) { Fail 'Unterminated JSON array in settings.json.' }
    return [pscustomobject]@{ Values = $values; Close = $Index }
}

function Get-RootObjectStart([string]$Text) {
    $Start = Skip-JsoncTrivia $Text 0
    if ($Start -ge $Text.Length -or $Text[$Start] -ne '{') { Fail 'settings.json must contain one root JSON object.' }
    return $Start
}

function Find-ObjectProperty($Layout, [string]$Name) {
    $matches = @($Layout.Properties | Where-Object Name -eq $Name)
    if ($matches.Count -gt 1) { Fail "settings.json contains multiple '$Name' properties." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-Newline([string]$Text) {
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Get-LineIndent([string]$Text, [int]$Index) {
    $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $Index - 1)) + 1
    $line = $Text.Substring($lineStart, $Index - $lineStart)
    if ($line -match '^[\t ]*$') { return $line }
    return ''
}

function Format-JsonFragment([string]$Fragment, [string]$Indent, [string]$Newline) {
    $normalized = $Fragment.Trim() -replace "`r?`n", "`n"
    return (($normalized -split "`n" | ForEach-Object { "$Indent$_" }) -join $Newline)
}

function Add-ObjectProperty([string]$Text, [int]$ObjectStart, [string]$Name, [string]$Value) {
    $layout = Get-ObjectLayout $Text $ObjectStart
    if (Find-ObjectProperty $layout $Name) { Fail "Property '$Name' already exists." }
    $newline = Get-Newline $Text
    $baseIndent = Get-LineIndent $Text $layout.Close
    $propertyIndent = if ($layout.Properties.Count -gt 0) { Get-LineIndent $Text $layout.Properties[0].KeyStart } else { "$baseIndent  " }

    if ($layout.Properties.Count -eq 0) {
        return $Text.Insert($layout.Close, "$newline$propertyIndent`"$Name`": $Value$newline$baseIndent")
    }

    $last = $layout.Properties[$layout.Properties.Count - 1]
    $afterLast = Skip-JsoncTrivia $Text $last.ValueEnd
    $close = $layout.Close
    if ($afterLast -ge $Text.Length -or $Text[$afterLast] -ne ',') {
        $Text = $Text.Insert($last.ValueEnd, ',')
        $close++
    }
    return $Text.Insert($close, "$newline$propertyIndent`"$Name`": $Value$newline$baseIndent")
}

function Add-ObjectToNamedArray([string]$Text, [string]$PropertyName, [string]$Name, [string]$Fragment) {
    $rootStart = Get-RootObjectStart $Text
    $root = Get-ObjectLayout $Text $rootStart
    $property = Find-ObjectProperty $root $PropertyName
    $newline = Get-Newline $Text

    if ($null -eq $property) {
        $baseIndent = Get-LineIndent $Text $root.Close
        $propertyIndent = if ($root.Properties.Count -gt 0) { Get-LineIndent $Text $root.Properties[0].KeyStart } else { "$baseIndent  " }
        $arrayIndent = "$propertyIndent  "
        $formatted = Format-JsonFragment $Fragment $arrayIndent $newline
        $value = "[$newline$formatted$newline$propertyIndent]"
        return Add-ObjectProperty $Text $rootStart $PropertyName $value
    }

    if ($Text[$property.ValueStart] -ne '[') { Fail "'$PropertyName' exists but is not an array." }
    $array = Get-ArrayLayout $Text $property.ValueStart
    foreach ($entry in $array.Values) {
        if ($Text[$entry.Start] -ne '{') { continue }
        $entryLayout = Get-ObjectLayout $Text $entry.Start
        $nameProperty = Find-ObjectProperty $entryLayout 'name'
        if ($null -ne $nameProperty -and $Text[$nameProperty.ValueStart] -eq '"' -and (Get-JsonStringValue $Text $nameProperty.ValueStart $nameProperty.ValueEnd) -eq $Name) {
            return $Text
        }
    }

    $baseIndent = Get-LineIndent $Text $array.Close
    $itemIndent = if ($array.Values.Count -gt 0) { Get-LineIndent $Text $array.Values[0].Start } else { "$baseIndent  " }
    $formatted = Format-JsonFragment $Fragment $itemIndent $newline
    if ($array.Values.Count -eq 0) {
        return $Text.Insert($array.Close, "$newline$formatted$newline$baseIndent")
    }

    $last = $array.Values[$array.Values.Count - 1]
    $afterLast = Skip-JsoncTrivia $Text $last.End
    $close = $array.Close
    if ($afterLast -ge $Text.Length -or $Text[$afterLast] -ne ',') {
        $Text = $Text.Insert($last.End, ',')
        $close++
    }
    return $Text.Insert($close, "$newline$formatted$newline$baseIndent")
}

function Set-StringProperty([string]$Text, [int]$ObjectStart, [string]$Name, [string]$Value) {
    $layout = Get-ObjectLayout $Text $ObjectStart
    $property = Find-ObjectProperty $layout $Name
    $encoded = $Value | ConvertTo-Json -Compress
    if ($null -eq $property) { return Add-ObjectProperty $Text $ObjectStart $Name $encoded }
    if ($Text[$property.ValueStart] -ne '"') { Fail "'$Name' must be a string in this object." }
    return $Text.Remove($property.ValueStart, $property.ValueEnd - $property.ValueStart).Insert($property.ValueStart, $encoded)
}

function Set-ThemeSelection([string]$Text, [int]$ObjectStart, [string]$Name, [string]$DarkSelection, [string]$LightSelection) {
    $layout = Get-ObjectLayout $Text $ObjectStart
    $property = Find-ObjectProperty $layout $Name
    if ($null -eq $property) {
        if ($DarkSelection -eq $LightSelection) { return Set-StringProperty $Text $ObjectStart $Name $DarkSelection }
        $Text = Add-ObjectProperty $Text $ObjectStart $Name '{}'
        $layout = Get-ObjectLayout $Text $ObjectStart
        $property = Find-ObjectProperty $layout $Name
    }
    if ($Text[$property.ValueStart] -eq '"') {
        if ($DarkSelection -eq $LightSelection) { return Set-StringProperty $Text $ObjectStart $Name $DarkSelection }
        $darkEncoded = $DarkSelection | ConvertTo-Json -Compress
        $lightEncoded = $LightSelection | ConvertTo-Json -Compress
        $value = "{ `"dark`": $darkEncoded, `"light`": $lightEncoded }"
        return $Text.Remove($property.ValueStart, $property.ValueEnd - $property.ValueStart).Insert($property.ValueStart, $value)
    }
    if ($Text[$property.ValueStart] -ne '{') { Fail "'$Name' must be a string or a dark/light object." }
    $Text = Set-StringProperty $Text $property.ValueStart 'dark' $DarkSelection
    return Set-StringProperty $Text $property.ValueStart 'light' $LightSelection
}

function Ensure-ProfileDefaults([string]$Text) {
    $rootStart = Get-RootObjectStart $Text
    $root = Get-ObjectLayout $Text $rootStart
    $profiles = Find-ObjectProperty $root 'profiles'
    if ($null -eq $profiles) {
        $Text = Add-ObjectProperty $Text $rootStart 'profiles' '{}'
        $root = Get-ObjectLayout $Text $rootStart
        $profiles = Find-ObjectProperty $root 'profiles'
    }
    if ($Text[$profiles.ValueStart] -ne '{') { Fail "'profiles' must be an object." }
    $profileObject = Get-ObjectLayout $Text $profiles.ValueStart
    $defaults = Find-ObjectProperty $profileObject 'defaults'
    if ($null -eq $defaults) {
        $Text = Add-ObjectProperty $Text $profiles.ValueStart 'defaults' '{}'
        $profileObject = Get-ObjectLayout $Text $profiles.ValueStart
        $defaults = Find-ObjectProperty $profileObject 'defaults'
    }
    if ($Text[$defaults.ValueStart] -ne '{') { Fail "'profiles.defaults' must be an object." }
    return [pscustomobject]@{ Text = $Text; DefaultsStart = $defaults.ValueStart }
}

function Remove-JsoncComments([string]$Text) {
    $builder = [System.Text.StringBuilder]::new()
    for ($Index = 0; $Index -lt $Text.Length;) {
        if ($Text[$Index] -eq '"') {
            $end = Get-JsonStringEnd $Text $Index
            [void]$builder.Append($Text.Substring($Index, $end - $Index))
            $Index = $end
            continue
        }
        if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq '/' -and $Text[$Index + 1] -eq '/') {
            $Index += 2
            while ($Index -lt $Text.Length -and $Text[$Index] -ne "`r" -and $Text[$Index] -ne "`n") { $Index++ }
            continue
        }
        if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq '/' -and $Text[$Index + 1] -eq '*') {
            $Index += 2
            while ($Index + 1 -lt $Text.Length -and -not ($Text[$Index] -eq '*' -and $Text[$Index + 1] -eq '/')) {
                if ($Text[$Index] -eq "`r" -or $Text[$Index] -eq "`n") { [void]$builder.Append($Text[$Index]) }
                $Index++
            }
            if ($Index + 1 -ge $Text.Length) { Fail 'Unterminated block comment in settings.json.' }
            $Index += 2
            continue
        }
        [void]$builder.Append($Text[$Index])
        $Index++
    }
    return $builder.ToString()
}

function Convert-JsoncToJson([string]$Text) {
    $withoutComments = Remove-JsoncComments $Text
    $builder = [System.Text.StringBuilder]::new()
    for ($Index = 0; $Index -lt $withoutComments.Length; $Index++) {
        if ($withoutComments[$Index] -eq '"') {
            $end = Get-JsonStringEnd $withoutComments $Index
            [void]$builder.Append($withoutComments.Substring($Index, $end - $Index))
            $Index = $end - 1
            continue
        }
        if ($withoutComments[$Index] -eq ',') {
            $next = $Index + 1
            while ($next -lt $withoutComments.Length -and [char]::IsWhiteSpace($withoutComments[$next])) { $next++ }
            if ($next -lt $withoutComments.Length -and $withoutComments[$next] -in @(']', '}')) { continue }
        }
        [void]$builder.Append($withoutComments[$Index])
    }
    return $builder.ToString()
}

function Test-Jsonc([string]$Text, [string]$Description) {
    try {
        $json = Convert-JsoncToJson $Text
        [void]($json | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Fail "$Description is not valid JSONC: $($_.Exception.Message)"
    }
}

function Get-WindowsTerminalSettingsPath([string]$RequestedPath) {
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) { Fail "The supplied settings file does not exist: $RequestedPath" }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }
    if (-not $env:LOCALAPPDATA) { Fail 'LOCALAPPDATA is not set. Pass -SettingsPath explicitly.' }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
    )
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($found.Count -eq 0) { Fail 'Windows Terminal settings.json was not found. Open Windows Terminal once, or pass -SettingsPath explicitly.' }
    if ($found.Count -gt 1) { Write-Warning "Multiple Windows Terminal settings files were found. Using: $($found[0])" }
    return $found[0]
}

try {
    $plan = $installPlans[$Variant]
    $settingsFile = Get-WindowsTerminalSettingsPath $SettingsPath
    $document = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8
    Test-Jsonc $document $settingsFile
    $rootStart = Get-RootObjectStart $document

    foreach ($variantName in $plan.Variants) {
        $details = $variantDetails[$variantName]
        $schemeFile = Join-Path $PSScriptRoot $details.Scheme
        $themeFile = Join-Path $PSScriptRoot $details.Theme
        foreach ($asset in @($schemeFile, $themeFile)) {
            if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) { Fail "Required repository asset is missing: $asset" }
        }
        $scheme = Get-Content -LiteralPath $schemeFile -Raw -Encoding UTF8
        $theme = Get-Content -LiteralPath $themeFile -Raw -Encoding UTF8
        Test-Jsonc $scheme $schemeFile
        Test-Jsonc $theme $themeFile
        $document = Add-ObjectToNamedArray $document 'schemes' $details.Name $scheme
        $document = Add-ObjectToNamedArray $document 'themes' $details.Name $theme
    }
    $defaults = Ensure-ProfileDefaults $document
    $document = Set-ThemeSelection $defaults.Text $defaults.DefaultsStart 'colorScheme' $plan.Dark $plan.Light
    $document = Set-ThemeSelection $document $rootStart 'theme' $plan.Dark $plan.Light
    Test-Jsonc $document 'The updated settings file'

    $original = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8
    if ($document -eq $original) {
        Write-Host "Rosé Pine $Variant is already installed in $settingsFile"
        exit 0
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $backup = "$settingsFile.rose-pine-backup-$timestamp.json"
    $backupSuffix = 1
    while (Test-Path -LiteralPath $backup) {
        $backup = "$settingsFile.rose-pine-backup-$timestamp-$backupSuffix.json"
        $backupSuffix++
    }
    Copy-Item -LiteralPath $settingsFile -Destination $backup -ErrorAction Stop
    $temporary = "$settingsFile.rose-pine-installing-$timestamp.tmp"
    try {
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($temporary, $document, $encoding)
        [System.IO.File]::Replace($temporary, $settingsFile, $backup, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }

    Write-Host "Installed Rosé Pine $Variant in $settingsFile"
    Write-Host "Backup created: $backup"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
