<p align="center"><img src="docs/images/icon.png" width="128" alt="Lemma's icon: a white λ on an olive tile"></p>

<h1 align="center">Lemma</h1>

<p align="center"><b>An IDE for reading mathematics.</b><br>
A free, open-source PDF reader for the Mac that understands textbooks and papers the way an editor understands code.</p>

<p align="center"><a href="https://github.com/fus3r/lemma/releases/latest/download/Lemma.dmg"><b>Download for macOS</b></a> · macOS 15 or later, Apple silicon and Intel</p>

<p align="center"><sub>Lemma is not notarized yet, so the first time you open it macOS says it cannot verify it: click <b>Done</b>, then <b>System Settings › Privacy &amp; Security › Open Anyway</b>. Only once.</sub></p>

<p align="center"><img src="docs/images/demo.gif" width="900" alt="Lemma reading its sample book: hovering “Theorem 1.3” previews it, clicking opens a peek beside the line, ⌘K asks about a proof with the equations it cites, proofs fold, and a derivation's wrong step is caught as a sign error, then fixed"></p>

Open any mathematics, statistics or computer science PDF. Lemma reads it once, on your Mac, and the page becomes navigable: “Theorem 2.3”, “(3.44)”, “Figure 5”, “[12]” and index entries turn into links you can preview, peek at and follow without losing your place.

## What Lemma does

**References you never have to hunt for.** Hover a reference to preview it, click to peek at it beside the line you are reading, ⇧-click others to keep several peeks in sight, ⌘-click a term to look up its definition. Back (⌥⌘←) returns you to where you were. Citations open their entry in the bibliography and can find the paper online when you ask.

**The structure of the text.** An outline of the book's definitions, theorems and proofs; proofs you can fold to try them yourself first; what a result uses and what uses it; a map of a chapter's dependencies; the notation in force on each line; and a header that tells you which statement you are in.

**Proofs, stepped through like a debugger.** Put the reading line in a proof and press F5: step over lines, step into the result a line cites, step out again, with the statement being proved and the symbols in scope beside you.

**Derivations checked as you write them.** Select a step the book calls "easily seen", press ⌥⌘E and write the missing lines in LaTeX. Each line is checked at once with random values of the right shapes (scalars, vectors, matrices), so a wrong step comes with a counterexample and a name: sign error, factor of 2, transposed.

**Python beside the page.** Send an equation to a notebook and run it on your Mac's own Python, gently on the battery. Figures can be pinned in the margin.

**Your work, kept with the source.** Notes, highlights, margin notes and handwriting stay linked to the exact passage. Recall definitions and theorems on a spaced schedule, collect passages from several books into research projects, and export everything: Markdown, Anki decks, Jupyter notebooks, or your annotated edition as a PDF.

**Separate workbenches.** File › New Window (⇧⌘N) opens an empty window, so Economics and CSD can have their own tabs and layout. Windows restore on relaunch and share your library and notes. Even two windows on the same book keep separate reading positions and Find queries. Edit › Undo (⌘Z) and Redo (⇧⌘Z) undo and restore notes, highlights, underlines and handwriting.

**Text and Markdown files.** Choose **File › Add New File…** or the Explorer's new-file button to create a `.txt` or `.md` file without a PDF. Files appear under **Workspace Files**, open in their own tabs and save automatically; ⌘S saves immediately. Markdown has a formatted preview, including mathematics. Closed files stay in the workspace, and open file tabs restore on relaunch. **Reveal File in Finder** opens the actual UTF-8 file.

Click a highlight and choose **Highlight › Remove Highlight**, or right-click it to remove it. Hold Shift and drag from a highlight toward the outside to extend it, or from near either end toward the inside to shorten it. Color rows show a preview; **Add Color…** opens the full macOS color palette, and **Edit Colors & Defaults…** lets you name and edit colors and set the defaults for ⇧⌘H and ⇧⌘U. Saved marks keep their colors when you edit the palette. Removing, resizing and recoloring marks supports Undo and Redo.

**Questions with the right context.** Select a passage and press ⌘K. Lemma assembles the passage, the equations it cites and your notation, shows you the draft, and asks ChatGPT, Codex, Claude Code, or OpenAI, Anthropic or Google with your own API key. Answers return to the note that asked; their algebra can be checked step by step.

**Everything else a reader needs.** Find in the book (⌘F) and search across your whole library, OCR for scanned pages, 45 free textbooks one click away, arXiv search, a minimap of your pages, Paper, Sepia and Night pages, and the choice between a VS Code-style workbench (Lemma's own themes, more than 80 VS Code themes, or any VS Code theme you install) and a classic Mac window.

<p align="center"><img src="docs/images/reading.png" width="900" alt="Lemma reading its sample book: the outline, the page with its references underlined, a peek at Theorem 1.3 opened from the proof that cites it, and the equations defined on the page"></p>

<p align="center"><img src="docs/images/welcome.png" width="900" alt="Lemma's Welcome page: open or drop a PDF, or start with a free textbook"></p>

## Install

Download [Lemma.dmg](https://github.com/fus3r/lemma/releases/latest/download/Lemma.dmg) (the [latest release](https://github.com/fus3r/lemma/releases/latest) has it under its version's name too), open it and drag Lemma into Applications. Lemma runs on macOS 15 (Sequoia) or later, on Apple silicon and Intel Macs.

This build is not yet notarized by Apple, so the first time you open it macOS says it cannot verify it. Click **Done**, then open **System Settings › Privacy & Security** and click **Open Anyway** next to Lemma (or run `xattr -dr com.apple.quarantine /Applications/Lemma.app`). You only do this once.

To see what Lemma does without a PDF at hand, choose **Help › Open the Sample Book**: a twelve-page book on least squares, written to show the links, the structure, the proof debugger and the derivation checker.

Lemma updates itself: **Lemma › Check for Updates…** installs a new version and relaunches. It checks on its own, once a day, only if you agree (it asks once).

## Privacy

Lemma has no account, no analytics and no tracking. Your books, notes and reading history stay on your Mac. It goes online only when you click something that says where it goes: downloading a free book, searching arXiv, looking up a cited paper, asking an assistant, checking for updates. [PRIVACY.md](PRIVACY.md) lists every case and what is sent.

## Build it yourself

```sh
git clone https://github.com/fus3r/lemma.git && cd lemma
scripts/build-app.sh && open build/Lemma.app
```

You need macOS 15 and Xcode 16 or later. [CONTRIBUTING.md](CONTRIBUTING.md) explains the layout of the code, the tests and how to contribute.

## Learn more

- [Using Lemma](docs/GUIDE.md): reading, notes, OCR, recall, questions and exports in detail.
- [Libraries](docs/LIBRARIES.md): folders, renames, drag and drop, arXiv.
- [Assistants](docs/ASSISTANTS.md): ChatGPT, Codex, Claude Code and API keys, and what each receives.
- [The Lemma Tour](docs/TUTORIAL.md), [design notes](DESIGN.md), [changelog](CHANGELOG.md) and [history](docs/HISTORY.md).

Found a bug or have an idea? Use **Help › Report an Issue…** in Lemma or [open an issue](https://github.com/fus3r/lemma/issues).

## License

Lemma is free software under the [GNU General Public License, version 3](LICENSE). It bundles Codicons (CC BY 4.0), colour themes from VS Code and their community authors (MIT, Apache 2.0), KaTeX (MIT) and its fonts (SIL Open Font License 1.1), Marked (MIT), DOMPurify (Apache 2.0) and Sparkle (MIT), which installs updates; **Help › Acknowledgements** shows every licence. Free textbooks in the catalog are downloaded from their authors' or publishers' sites and remain under their own terms.
