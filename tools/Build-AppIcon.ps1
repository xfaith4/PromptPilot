[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceImage,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\assets'),
    [string]$OutputBaseName = 'prompt-pilot',
    [int]$CropX = 0,
    [int]$CropY = 110,
    [int]$CropSize = 530,
    [int]$TransparencyThreshold = 245
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function Resolve-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

$sourcePath = Resolve-NormalizedPath -Path $SourceImage
$assetDirectory = Resolve-NormalizedPath -Path $OutputDirectory

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Source image not found: $sourcePath"
}

if (-not (Test-Path -LiteralPath $assetDirectory)) {
    New-Item -ItemType Directory -Path $assetDirectory -Force | Out-Null
}

$pngPath = Join-Path $assetDirectory ($OutputBaseName + '.png')
$icoPath = Join-Path $assetDirectory ($OutputBaseName + '.ico')

$sourceBitmap = [System.Drawing.Bitmap]::new($sourcePath)

try {
    if (($CropX + $CropSize) -gt $sourceBitmap.Width -or ($CropY + $CropSize) -gt $sourceBitmap.Height) {
        throw "Crop rectangle exceeds source image bounds. Source size: $($sourceBitmap.Width)x$($sourceBitmap.Height)"
    }

    $cropRect = [System.Drawing.Rectangle]::new($CropX, $CropY, $CropSize, $CropSize)
    $croppedBitmap = [System.Drawing.Bitmap]::new($CropSize, $CropSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

    try {
        $graphics = [System.Drawing.Graphics]::FromImage($croppedBitmap)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.DrawImage($sourceBitmap, [System.Drawing.Rectangle]::new(0, 0, $CropSize, $CropSize), $cropRect, [System.Drawing.GraphicsUnit]::Pixel)
        }
        finally {
            $graphics.Dispose()
        }

        for ($x = 0; $x -lt $croppedBitmap.Width; $x++) {
            for ($y = 0; $y -lt $croppedBitmap.Height; $y++) {
                $pixel = $croppedBitmap.GetPixel($x, $y)
                if ($pixel.R -ge $TransparencyThreshold -and $pixel.G -ge $TransparencyThreshold -and $pixel.B -ge $TransparencyThreshold) {
                    $croppedBitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $pixel.R, $pixel.G, $pixel.B))
                }
            }
        }

        $croppedBitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $croppedBitmap.Dispose()
    }
}
finally {
    $sourceBitmap.Dispose()
}

$iconBitmap = [System.Drawing.Bitmap]::new(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
try {
    $graphics = [System.Drawing.Graphics]::FromImage($iconBitmap)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.DrawImage([System.Drawing.Image]::FromFile($pngPath), [System.Drawing.Rectangle]::new(0, 0, 256, 256))
    }
    finally {
        $graphics.Dispose()
    }

    $pngStream = [System.IO.MemoryStream]::new()
    try {
        $iconBitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $pngStream.ToArray()
    }
    finally {
        $pngStream.Dispose()
    }

    $fileStream = [System.IO.File]::Open($icoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = [System.IO.BinaryWriter]::new($fileStream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$pngBytes.Length)
        $writer.Write([UInt32]22)
        $writer.Write($pngBytes)
    }
    finally {
        $writer.Dispose()
        $fileStream.Dispose()
    }
}
finally {
    $iconBitmap.Dispose()
}

Write-Host 'App icon assets created:' -ForegroundColor Green
Write-Host "  $pngPath"
Write-Host "  $icoPath"
