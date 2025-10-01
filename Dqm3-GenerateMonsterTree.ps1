<#
Generates a markdown synthesis guide for a Dragon Quest Monsters creature by using Game8 data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MonsterName,

    [string]$OutputDirectory = '.',

    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ModulePath {
    param(
        [string]$ModuleName,
        [string]$DllRelativePath
    )

    $cacheRoot = Join-Path -Path $PSScriptRoot -ChildPath '.cache'
    if (-not (Test-Path $cacheRoot)) {
        New-Item -ItemType Directory -Path $cacheRoot | Out-Null
    }

    $moduleRoot = Join-Path -Path $cacheRoot -ChildPath $ModuleName
    $dllPath = Join-Path -Path $moduleRoot -ChildPath $DllRelativePath

    if (-not (Test-Path $dllPath)) {
        Write-Verbose "Downloading $ModuleName via NuGet"
        $nupkgPath = Join-Path -Path $cacheRoot -ChildPath "$ModuleName.nupkg"
        $nugetUrl = "https://www.nuget.org/api/v2/package/$ModuleName"
        Invoke-WebRequest -Uri $nugetUrl -OutFile $nupkgPath -UseBasicParsing | Out-Null
        if (Test-Path $moduleRoot) { Remove-Item -Recurse -Force $moduleRoot }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkgPath, $moduleRoot)
        Remove-Item $nupkgPath -Force
    }

    return $dllPath
}

function Ensure-HtmlAgilityPack {
    if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'HtmlAgilityPack' })) {
        $dllPath = Resolve-ModulePath -ModuleName 'HtmlAgilityPack' -DllRelativePath 'lib/netstandard2.0/HtmlAgilityPack.dll'
        Add-Type -Path $dllPath
    }
}

Ensure-HtmlAgilityPack
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Drawing

function Get-HtmlDocument {
    param(
        [string]$Uri
    )

    $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
    $response = Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing
    $doc = [HtmlAgilityPack.HtmlDocument]::new()
    $doc.LoadHtml($response.Content)
    return $doc
}

function Get-MappingDataset {
    param(
        [switch]$ForceRefresh
    )

    $cacheRoot = Join-Path -Path $PSScriptRoot -ChildPath '.cache'
    if (-not (Test-Path $cacheRoot)) {
        New-Item -ItemType Directory -Path $cacheRoot | Out-Null
    }
    $cacheFile = Join-Path -Path $cacheRoot -ChildPath 'dqm3_mapping.json'
    if ((-not $ForceRefresh) -and (Test-Path $cacheFile)) {
        return (Get-Content $cacheFile -Raw | ConvertFrom-Json)
    }

    $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; 'Referer' = 'https://game8.co/games/DQM-Dark-Prince/archives/435994' }
    $json = Invoke-WebRequest -Uri 'https://game8.co/api/tool_structural_mappings/172.json' -Headers $headers -UseBasicParsing | Select-Object -ExpandProperty Content
    Set-Content -Path $cacheFile -Value $json -Encoding utf8
    return $json | ConvertFrom-Json
}

function Get-MonsterOverview {
    param(
        [HtmlAgilityPack.HtmlDocument]$Doc
    )

    $header = $Doc.DocumentNode.SelectSingleNode("//h2[contains(text(),'Traits, Weaknesses')]")
    if (-not $header) { return $null }

    $table = $header.SelectSingleNode("following-sibling::table[1]")
    if (-not $table) { return $null }

    $rows = $table.SelectNodes('.//tr')
    $info = [ordered]@{}

    foreach ($row in $rows) {
        $cells = $row.SelectNodes('./th|./td')
        if (-not $cells) { continue }

        if ($cells.Count -ge 3) {
            $keyNode = $cells[1]
            $valueNode = $cells[2]
        } elseif ($cells.Count -ge 2) {
            $keyNode = $cells[0]
            $valueNode = $cells[1]
        } else {
            continue
        }

        $key = $keyNode.InnerText.Trim()

        $linkNodes = $valueNode.SelectNodes('.//a')
        if ($linkNodes) {
            $valueParts = @()
            foreach ($link in $linkNodes) {
                $linkText = $link.InnerText.Trim()
                if ($linkText) { $valueParts += $linkText }
            }
            $value = ($valueParts -join ', ')
        } else {
            $value = $valueNode.InnerText.Trim()
        }

        if ($key -eq 'Rank') {
            $rankImage = $valueNode.SelectSingleNode(".//img[@alt]")
            if ($rankImage) {
                $altText = $rankImage.GetAttributeValue('alt', '').Trim()
                if ($altText) {
                    $value = ($altText -replace '\s+Image$', '').Trim()
                }
            }
        }

        if ($key -and $value) { $info[$key] = $value }
    }

    $imageNode = $table.SelectSingleNode(".//img[@data-src]")
    if (-not $imageNode) { $imageNode = $table.SelectSingleNode(".//img[@src]") }
    $imageUrl = if ($imageNode) { $imageNode.GetAttributeValue('data-src', $imageNode.GetAttributeValue('src', '')) } else { '' }

    return [pscustomobject]@{
        Number = $info['No.']
        Family = $info['Family']
        Rank = $info['Rank']
        Talents = $info['Talents']
        ImageUrl = $imageUrl
    }
}

function Sanitize-Id {
    param([string]$Name)
    ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}


$FamilyRankDefaults = @{
    'beast-family'    = 'Any'
    'demon-family'    = 'Any'
    'dragon-family'   = 'Any'
    'material-family' = 'Any'
    'nature-family'   = 'Any'
    'slime-family'    = 'Any'
    'undead-family'   = 'Any'
    'family'          = 'Any'
}

function Get-FamilyRank {
    param(
        [string]$Name,
        [string]$RequestedRank,
        [string]$ParentSource
    )

    if (-not $Name) { return '' }

    $normalized = Sanitize-Id $Name
    if (-not $FamilyRankDefaults.ContainsKey($normalized)) { return '' }

    if ($ParentSource -and $ParentSource -ne 'Normal') {
        return 'Any'
    }

    if ($RequestedRank) {
        $candidate = $RequestedRank.Trim()
        if ($candidate) {
            $upper = $candidate.ToUpperInvariant()
            if ($upper -eq 'ANY') { return 'Any' }
            if ($upper -match '^[A-Z+]{1,3}$') { return $upper }
        }
    }

    return $FamilyRankDefaults[$normalized]
}

function Get-FamilyImagePath {
    param([string]$Name)

    if (-not $Name) { return $null }

    $normalized = Sanitize-Id $Name
    $families = @(
        'beast-family',
        'demon-family',
        'dragon-family',
        'material-family',
        'nature-family',
        'slime-family',
        'undead-family'
    )

    if ($families -contains $normalized) {
        return "images/$normalized.jpg"
    }

    return $null
}

function New-SynthesisNode {
    param(
        $LookupNode,
        [string]$FallbackName,
        [object[]]$Children,
        [string]$Source,
        [hashtable]$DuplicateCounts,
        [string]$RequiredRank = '',
        [string]$ParentSource = '',
        [switch]$IsDuplicate
    )

    $name = if ($LookupNode) { $LookupNode.name } else { $FallbackName }
    $rank = if ($LookupNode) { $LookupNode.rank } else { '' }
    if (-not $rank) {
        $familyRank = Get-FamilyRank -Name $name -RequestedRank $RequiredRank -ParentSource $ParentSource
        if ($familyRank) { $rank = $familyRank }
    }
    $imageUrl = if ($LookupNode) { $LookupNode.imageUrl } else { '' }
    $monsterId = if ($LookupNode) { $LookupNode.monsterId } else { $null }
    $lookupId = if ($LookupNode) { $LookupNode.id } else { $null }
    $baseKey = Sanitize-Id $name
    if (-not $baseKey) {
        $fallbackId = if ($lookupId) { [string]$lookupId } elseif ($monsterId) { [string]$monsterId } else { $null }
        $baseKey = if ($fallbackId) { Sanitize-Id $fallbackId } else { 'monster' }
    }

    if (-not $DuplicateCounts.ContainsKey($baseKey)) {
        $DuplicateCounts[$baseKey] = 0
    }

    $duplicateIndex = 0
    $nodeKey = $baseKey
    $nodeChildren = $Children
    if ($IsDuplicate) {
        $DuplicateCounts[$baseKey] = [int]$DuplicateCounts[$baseKey] + 1
        $duplicateIndex = $DuplicateCounts[$baseKey]
        $nodeKey = "$baseKey-ex$duplicateIndex"
        $nodeChildren = @()
    }

    $localImage = Get-FamilyImagePath -Name $name
    $effectiveSource = if ($Source) { $Source } else { 'Leaf' }

    return [pscustomobject]@{
        Name = $name
        Rank = $rank
        ImageUrl = $imageUrl
        LocalImage = $localImage
        Children = $nodeChildren
        Source = $effectiveSource
        MonsterId = $baseKey
        NodeKey = $nodeKey
        BaseNodeKey = $baseKey
        DuplicateIndex = $duplicateIndex
        IsDuplicate = [bool]$IsDuplicate
    }
}


function Build-SynthesisTree {
    param(
        [hashtable]$Lookup,
        [string]$Name,
        [System.Collections.Generic.HashSet[string]]$Visited,
        [hashtable]$DuplicateCounts,
        [string]$RequiredParentRank = '',
        [string]$ParentSource = ''
    )

    $node = if ($Lookup.ContainsKey($Name)) { $Lookup[$Name] } else { $null }

    $childrenNames = @()
    $source = 'Leaf'
    if ($node) {
        $source = 'Normal'
        if ($node.specialSynthesis.parentMonster1.name -or $node.specialSynthesis.parentMonster2.name) {
            $source = 'Special'
            $childrenNames = @($node.specialSynthesis.parentMonster1.name, $node.specialSynthesis.parentMonster2.name)
        } elseif ($node.quadrupleSynthesis.parentMonster1.name -or $node.quadrupleSynthesis.parentMonster2.name -or $node.quadrupleSynthesis.parentMonster3.name -or $node.quadrupleSynthesis.parentMonster4.name) {
            $source = 'Quadruple'
            $childrenNames = @(
                $node.quadrupleSynthesis.parentMonster1.name,
                $node.quadrupleSynthesis.parentMonster2.name,
                $node.quadrupleSynthesis.parentMonster3.name,
                $node.quadrupleSynthesis.parentMonster4.name
            )
        } elseif ($node.synthesis.parentMonster1.name -or $node.synthesis.parentMonster2.name) {
            $source = 'Normal'
            $childrenNames = @($node.synthesis.parentMonster1.name, $node.synthesis.parentMonster2.name)
        }
    }

    if ($Visited.Contains($Name)) {
        return New-SynthesisNode -LookupNode $node -FallbackName $Name -Children @() -Source $source -DuplicateCounts $DuplicateCounts -RequiredRank $RequiredParentRank -ParentSource $ParentSource -IsDuplicate
    }

    $Visited.Add($Name) | Out-Null

    $children = @()
    $nextRequiredRank = if ($node) { $node.rank } else { '' }
    foreach ($childName in $childrenNames | Where-Object { $_ -and $_.Trim() -ne '' }) {
        $childTree = Build-SynthesisTree -Lookup $Lookup -Name $childName.Trim() -Visited $Visited -DuplicateCounts $DuplicateCounts -RequiredParentRank $nextRequiredRank -ParentSource $source
        if ($childTree) { $children += $childTree }
    }

    return New-SynthesisNode -LookupNode $node -FallbackName $Name -Children $children -Source $source -DuplicateCounts $DuplicateCounts -RequiredRank $RequiredParentRank -ParentSource $ParentSource
}



function Flatten-Nodes {
    param($Root)
    $list = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($Root)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if (-not $seen.Add($node.NodeKey)) { continue }
        $list.Add($node)
        foreach ($child in $node.Children) { $queue.Enqueue($child) }
    }
    return $list
}



function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Download-Image {
    param(
        [string]$Uri,
        [string]$TargetPath
    )

    if (-not $Uri) { return }

    $expectedSize = 96

    $existingImage = $null
    $alreadySized = $false
    if (Test-Path $TargetPath) {
        try {
            $existingImage = [System.Drawing.Image]::FromFile($TargetPath)
            if ($existingImage.Width -eq $expectedSize -and $existingImage.Height -eq $expectedSize) {
                $alreadySized = $true
            }
        } catch {
            $alreadySized = $false
        } finally {
            if ($existingImage) { $existingImage.Dispose() }
        }

        if ($alreadySized) { return }
    }

    $client = [System.Net.WebClient]::new()
    try {
        $client.Headers['User-Agent'] = 'Mozilla/5.0'
        $bytes = $client.DownloadData($Uri)
    } finally {
        $client.Dispose()
    }

    $memoryStream = $null
    $image = $null
    $bitmap = $null
    $graphics = $null

    try {
        $memoryStream = [System.IO.MemoryStream]::new($bytes)
        $image = [System.Drawing.Image]::FromStream($memoryStream)

        $bitmap = New-Object System.Drawing.Bitmap $expectedSize, $expectedSize
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($image, 0, 0, $expectedSize, $expectedSize)

        $jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        if ($jpegEncoder) {
            $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters 1
            $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]90)
            $bitmap.Save($TargetPath, $jpegEncoder, $encoderParams)
        } else {
            $bitmap.Save($TargetPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
    } catch {
        [System.IO.File]::WriteAllBytes($TargetPath, $bytes)
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($image) { $image.Dispose() }
        if ($memoryStream) { $memoryStream.Dispose() }
    }
}

function Build-Mermaid {
    param(
        $Root,
        $ImageMap
    )

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('```mermaid')
    $null = $sb.AppendLine('graph LR')
    $null = $sb.AppendLine('    classDef current stroke:#90CAF9,fill:#1565C0;')
    $null = $sb.AppendLine('    classDef scout stroke:#FFB74D,fill:#E65100;')
    $null = $sb.AppendLine('    classDef duplicated stroke:#81C784,fill:#2E7D32;')

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $nodeData = @{}
    $edgeTuples = [System.Collections.Generic.List[object]]::new()
    $edgeKeys = [System.Collections.Generic.HashSet[string]]::new()

    $queue.Enqueue($Root)

    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if (-not $visited.Add($node.NodeKey)) { continue }

        $nodeId = Sanitize-Id $node.NodeKey
        $label = "$($node.Name) ($($node.Rank))"
        $img = if ($ImageMap.ContainsKey($node.NodeKey)) { "<img src=`"$($ImageMap[$node.NodeKey])`" />" } else { '' }

        $nodeData[$nodeId] = [pscustomobject]@{
            Label = $label
            Image = $img
        }

        foreach ($child in $node.Children) {
            $queue.Enqueue($child)

            $childId = Sanitize-Id $child.NodeKey
            $childLabel = "$($child.Name) ($($child.Rank))"
            $childImg = if ($ImageMap.ContainsKey($child.NodeKey)) { "<img src=`"$($ImageMap[$child.NodeKey])`" />" } else { '' }

            $nodeData[$childId] = [pscustomobject]@{
                Label = $childLabel
                Image = $childImg
            }

            $edgeKey = "$childId|$nodeId"
            if ($edgeKeys.Add($edgeKey)) {
                $edgeTuples.Add([pscustomobject]@{ From = $childId; To = $nodeId })
            }
        }
    }

    $sortedNodeIds = $nodeData.Keys | Sort-Object
    foreach ($nodeId in $sortedNodeIds) {
        $nodeEntry = $nodeData[$nodeId]
        $null = $sb.AppendLine(('    {0}["{1}"{2}]' -f $nodeId, $nodeEntry.Label, $nodeEntry.Image))
    }

    $sortedEdges = $edgeTuples | Sort-Object -Property From, To
    foreach ($edge in $sortedEdges) {
        $null = $sb.AppendLine("    $($edge.To) --- $($edge.From)")
    }

    $null = $sb.AppendLine('```')
    return $sb.ToString()
}


# Load mapping dataset and lookup monster
$mapping = Get-MappingDataset
$lookup = @{}
foreach ($monster in $mapping.monsterArraySchema.monsters) {
    $lookup[$monster.name] = $monster
}

if (-not $lookup.ContainsKey($MonsterName)) {
    throw "Unable to find '$MonsterName' in the mapping dataset."
}

$monsterEntry = $lookup[$MonsterName]
$detailUrl = if ($monsterEntry.url) { $monsterEntry.url } else { throw "Mapping data for '$MonsterName' is missing a detail URL." }

$doc = Get-HtmlDocument -Uri $detailUrl
$overview = Get-MonsterOverview -Doc $doc

$visited = [System.Collections.Generic.HashSet[string]]::new()
$duplicateCounts = @{}
$root = Build-SynthesisTree -Lookup $lookup -Name $MonsterName -Visited $visited -DuplicateCounts $duplicateCounts
$nodes = Flatten-Nodes -Root $root

Ensure-Directory -Path $OutputDirectory
$outputRoot = (Resolve-Path -Path $OutputDirectory).Path

$imagesDir = Join-Path -Path $outputRoot -ChildPath 'images'
Ensure-Directory -Path $imagesDir

$assetsImagesDir = Join-Path -Path $PSScriptRoot -ChildPath 'assets/images'
if (Test-Path $assetsImagesDir) {
    # Pre-seed the output directory with bundled images
    Copy-Item -Path (Join-Path $assetsImagesDir '*') -Destination $imagesDir -Recurse -Force
}

$imageMap = @{}
$baseImageCache = @{}
foreach ($node in $nodes) {
    $nodeKey = $node.NodeKey
    $baseKey = $node.BaseNodeKey

    if ($node.LocalImage) {
        if (-not $baseImageCache.ContainsKey($baseKey)) { $baseImageCache[$baseKey] = $node.LocalImage }
        $imageMap[$nodeKey] = $baseImageCache[$baseKey]
        continue
    }

    if ($baseImageCache.ContainsKey($baseKey)) {
        $imageMap[$nodeKey] = $baseImageCache[$baseKey]
        continue
    }

    if (-not $node.ImageUrl) { continue }

    $fileName = "$(Sanitize-Id $baseKey).jpg"
    $targetPath = Join-Path $imagesDir $fileName
    Download-Image -Uri $node.ImageUrl -TargetPath $targetPath
    $relativePath = "images/$fileName"
    $baseImageCache[$baseKey] = $relativePath
    $imageMap[$nodeKey] = $relativePath
}

$mermaid = Build-Mermaid -Root $root -ImageMap $imageMap

$markdown = [System.Text.StringBuilder]::new()
$null = $markdown.AppendLine("# $MonsterName")
$null = $markdown.AppendLine()
if ($overview) {
    $null = $markdown.AppendLine("- **Number:** $($overview.Number)")
    $null = $markdown.AppendLine("- **Family:** $($overview.Family)")
    $null = $markdown.AppendLine("- **Rank:** $($overview.Rank)")
    $null = $markdown.AppendLine()
}
$null = $markdown.AppendLine('## Synthesis')
$null = $markdown.AppendLine()
$null = $markdown.AppendLine($mermaid)

$outputFile = Join-Path -Path $outputRoot -ChildPath ("$(Sanitize-Id $MonsterName).md")
if ((Test-Path $outputFile) -and (-not $Overwrite)) {
    throw "File '$outputFile' already exists. Use -Overwrite to replace."
}
$markdown.ToString() | Set-Content -Path $outputFile -Encoding utf8

Write-Host "Created markdown: $outputFile"
# Example usage:
# .\Generate-MonsterMarkdown.ps1 -MonsterName "Slime Knight" -OutputDirectory ".\output" -Overwrite