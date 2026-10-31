# NECXA Flutter

A cross-platform NECXA experience with a web deployment target for GitHub Pages.

## Web deployment

The repository includes a GitHub Actions workflow at `.github/workflows/deploy-web-to-pages.yml` that builds the Flutter web app and publishes it to GitHub Pages on pushes to `main`.

### Local build

```bash
flutter build web --release --base-href "/necxa.app/"
```

### GitHub Pages setup

1. In GitHub, open Settings → Pages.
2. Set Source to "GitHub Actions".
3. Push to `main` or trigger the workflow manually.

The workflow will publish the generated web bundle under your repository Pages URL.
