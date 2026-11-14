Add-Type -AssemblyName System.Drawing

$sourcePath = 'C:\Users\KNEST\.gemini\antigravity\brain\37e25620-3e58-45f9-92aa-262cf7f4d90b\.user_uploaded\media_1791491399610.png'
$destPath = 'c:\Users\KNEST\necxa app\necxa.app\assets\images\app_icon_padded.png'

$img = [System.Drawing.Image]::FromFile($sourcePath)
$newWidth = $img.Width
$newHeight = $img.Height

# We want the icon to be reduced by 5%, which means it occupies 95% of the space.
# So the padded image size is same, but we draw the original image scaled down by 0.95 in the center.

$bitmap = New-Object System.Drawing.Bitmap($newWidth, $newHeight)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)

# Set high quality
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# Clear with transparent background
$graphics.Clear([System.Drawing.Color]::Transparent)

$scale = 0.90  # Reduced to 90% to give a 5% border on each side (total 10% reduction gives 5% bezel)
$drawWidth = [int]($newWidth * $scale)
$drawHeight = [int]($newHeight * $scale)
$x = [int](($newWidth - $drawWidth) / 2)
$y = [int](($newHeight - $drawHeight) / 2)

$graphics.DrawImage($img, $x, $y, $drawWidth, $drawHeight)

$bitmap.Save($destPath, [System.Drawing.Imaging.ImageFormat]::Png)

$graphics.Dispose()
$bitmap.Dispose()
$img.Dispose()

Write-Host "Padded image saved to $destPath"
