from PIL import Image

path = r'C:/Users/KNEST/.gemini/antigravity/brain/37e25620-3e58-45f9-92aa-262cf7f4d90b/.user_uploaded/media_1791493009741.png'
img = Image.open(path)
print(f'Format: {img.format}, Size: {img.size}, Mode: {img.mode}')
