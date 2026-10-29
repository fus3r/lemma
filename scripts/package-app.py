"""Package locally built native executables; no signing identity or publication."""
import json
import plistlib
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
bundle = Path(sys.argv[1])
companion = bundle / "Contents/Resources/Chrome Companion"
identity = json.loads((root / "browser/identity.json").read_text())
manifest = json.loads((root / "browser/manifest.json").read_text())
manifest["key"] = identity["key"]
for name in ("background.js", "arxiv.js", "dom.js", "content.js", "identity.json"):
    shutil.copy2(root / "browser" / name, companion / name)
(companion / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
# Chrome's folder picker does not expose app bundle contents like ordinary folders.
visible_companion = bundle.parent / "Chrome Companion"
shutil.copytree(companion, visible_companion, dirs_exist_ok=True)
shutil.copytree(root / "Sources/Lemma/Resources/Math", bundle / "Contents/Resources/Math", dirs_exist_ok=True)
# 2.0: VS Code colour themes (with their licences) and the codicon font (CC BY 4.0).
for folder in ("Themes", "Codicons", "Assistant", "Sample", "Licenses"):
    shutil.copytree(root / "Sources/Lemma/Resources" / folder, bundle / "Contents/Resources" / folder, dirs_exist_ok=True)
shutil.copy2(root / "LICENSE", bundle / "Contents/Resources/LICENSE.txt")
info = {
    "CFBundleName": "Lemma", "CFBundleDisplayName": "Lemma",
    "CFBundleIdentifier": "com.lemma.app", "CFBundleExecutable": "Lemma",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "3.4.1",
    "CFBundleVersion": "46", "LSMinimumSystemVersion": "15.0",
    "LSApplicationCategoryType": "public.app-category.education",
    "NSHighResolutionCapable": True,
    "CFBundleIconFile": "Lemma.icns",
    # lemma://open?book=<fingerprint>&ref=Theorem%202.3 (or &page=<pdf page>) opens a place in a book from other apps.
    "CFBundleURLTypes": [{"CFBundleURLName": "com.lemma.app.link", "CFBundleURLSchemes": ["lemma"]}],
    # 3.0: Lemma is offered in Finder's Open With menu for PDFs and accepts PDFs dropped on its Dock icon.
    "CFBundleDocumentTypes": [{"CFBundleTypeName": "PDF Document", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
                               "LSItemContentTypes": ["com.adobe.pdf"]}],
    "NSHumanReadableCopyright": "Copyright © 2026 the Lemma contributors. Free software under the GNU GPL v3.",
    # 2.4: rows dragged inside the Library tree (between libraries, folders and sections).
    "UTExportedTypeDeclarations": [{"UTTypeIdentifier": "com.lemma.library-items", "UTTypeDescription": "Lemma Library items",
                                    "UTTypeConformsTo": ["public.data"], "UTTypeTagSpecification": {}}],
    # 3.1: updates through Sparkle. Each GitHub release publishes the appcast beside its disk image; both are signed with
    # the project's EdDSA key, and Sparkle asks the reader at the second launch before checking on its own (once a day).
    "SUFeedURL": "https://github.com/fus3r/lemma/releases/latest/download/appcast.xml",
    "SUPublicEDKey": "KoHep0rUqTengXG//fx6NTQl+51MkljJWgSssFbCNLc=",
    "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True, "SUScheduledCheckInterval": 86400,
    # Two free books of the catalog are served over plain HTTP by their authors (their HTTPS certificates are self-signed).
    "NSAppTransportSecurity": {"NSExceptionDomains": {
        "incompleteideas.net": {"NSExceptionAllowsInsecureHTTPLoads": True, "NSIncludesSubdomains": True},
        "web4.cs.ucl.ac.uk": {"NSExceptionAllowsInsecureHTTPLoads": True, "NSIncludesSubdomains": False},
    }},
}
with (bundle / "Contents/Info.plist").open("wb") as file:
    plistlib.dump(info, file)
# 3.2.2: the helper that reads books has a bundle of its own (scripts/build-app.sh), background-only, so the Dock never
# shows it. In Contents/MacOS it took Lemma's identity and showed up as another Lemma.
helper = {
    "CFBundleName": "LemmaIndexer", "CFBundleIdentifier": "com.lemma.app.indexer", "CFBundleExecutable": "LemmaIndexer",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": info["CFBundleShortVersionString"],
    "CFBundleVersion": info["CFBundleVersion"], "LSMinimumSystemVersion": info["LSMinimumSystemVersion"],
    "LSBackgroundOnly": True,
}
with (bundle / "Contents/Helpers/LemmaIndexer.app/Contents/Info.plist").open("wb") as file:
    plistlib.dump(helper, file)
