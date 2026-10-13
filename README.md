# INV

INV is a native macOS invoice application for creating, editing, importing, and exporting invoices.

The `web/` directory is a browser version that can be published on GitHub Pages. It keeps saved invoices in the browser's local storage and uses the browser print dialog to create a PDF, so no invoice data is sent to a server.

## Source layout

- `Sources/INV.swift` — main application and invoice editor
- `Sources/Accounting.swift` — accounting and invoice data support
- `Build/Info.plist` — app bundle metadata
- `Build/INV.icns` — application icon
- `web/` — static browser app for GitHub Pages
- `.github/workflows/pages.yml` — deploys `web/` after a push to `main`

## Build locally

The app is built with the Swift toolchain and macOS frameworks:

```sh
mkdir -p Build/INV.app/Contents/MacOS
swiftc Sources/INV.swift Sources/Accounting.swift \
  -o Build/INV.app/Contents/MacOS/INV \
  -framework SwiftUI -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers
cp Build/Info.plist Build/INV.app/Contents/Info.plist
cp Build/INV.icns Build/INV.app/Contents/Resources/INV.icns
open Build/INV.app
```

Build products, recovery copies, logs, and local invoice data are intentionally excluded from version control.

## Publish the web app on GitHub Pages

The repository needs GitHub Pages enabled with the **GitHub Actions** source. After the first push to `main`, the workflow deploys the contents of `web/` and GitHub shows the published URL under **Settings → Pages**. GitHub Pages serves static files, so the web app uses browser-local storage rather than a shared database.

## Privacy

Keep this repository private. The app supports user-configured business and payment details; do not publish personal or customer information.
