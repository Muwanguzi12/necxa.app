Add-Type -AssemblyName System.Drawing

$srcPath = "C:/Users/KNEST/.gemini/antigravity/brain/37e25620-3e58-45f9-92aa-262cf7f4d90b/.user_uploaded/media_1791493009741.png"
$destPath = "c:/Users/KNEST/necxa app/necxa.app/assets/images/app_icon_padded.png"

$srcImg = [System.Drawing.Image]::FromFile($srcPath)

$canvasSize = 1024
$targetSize = [math]::Round($canvasSize * 0.90) # A slightly bigger bezel visually might be better, let's do 90%? Wait, user asked for exactly 5%. Let's use 0.95.
$targetSize = [math]::Round($canvasSize * 0.95)
$offset = ($canvasSize - $targetSize) / 2

$bmp = New-Object System.Drawing.Bitmap($canvasSize, $canvasSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)

# Set high quality
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# Clear with transparent
$g.Clear([System.Drawing.Color]::Transparent)

# Draw image
$rect = New-Object System.Drawing.Rectangle($offset, $offset, $targetSize, $targetSize)
$g.DrawImage($srcImg, $rect)

$bmp.Save($destPath, [System.Drawing.Imaging.ImageFormat]::Png)

$g.Dispose()
$bmp.Dispose()
$srcImg.Dispose()

Write-Host "Image successfully padded and saved to $destPath"
