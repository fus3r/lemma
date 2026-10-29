# Changelog

The detailed notes written for each version before 3.0 are in [docs/HISTORY.md](docs/HISTORY.md).

## 3.4.1 (October 2026)

- Find keeps each book's query when switching tabs, without searching the next book or moving its reading position. Adapted from Songlan Nie's fork.
- Classic Find uses up/down chevrons for previous/next matches; missing Classic icon mappings now have their corresponding SF Symbols. By Songlan Nie.
- A parenthesized PDF link to a numbered statement, such as Result 3.21 in Axler, uses the statement's name when the book analysis and link destination agree. Ambiguous links and actual equations retain their labels.
- Tabs keep their width while the Explorer is resized.
- Dragging a tab to the right moves it into the target's place, including the last position. Adapted from Songlan Nie's fork.
- If an older downloaded update is waiting to install, Check for Updates can set it aside and offer the newest release.

## 3.4.0 (October 2026)

**Peeks you can keep in sight.**
- **Move a peek** by dragging its title bar: it then stays open while you read on, scroll and click elsewhere, until you close it. In the Classic window, drag the popover away from its reference.
- **⇧-click another reference** to open its peek beside the ones already open, so that a figure and the theorem that uses it stay in sight together. ⇧-clicking a reference whose peek is open brings that peek forward; with text selected, ⇧-click still extends the selection.
- Peeks open with the page at a little less than your reading zoom, as wide as the page and within 70% of the window, instead of 556 points whatever the zoom. Drag a peek's right edge, its bottom edge or the corner between them to resize it, and the page refits to the new width. By Songlan Nie.

**Fixed.**
- The Classic peek no longer grows off the screen's edge away from its reference, and resizing a peek dragged away from its reference no longer makes Lemma quit. By Songlan Nie.
- The Library shows it is scanning from the moment a PDF is dropped on it, instead of reading as up to date until the PDF appears. By Songlan Nie.

## 3.3.1 (October 2026)

**Fixed.**
- Single Page, Two Pages and Two Pages Continuous, chosen in the page's context menu, lasted a moment before Lemma put Continuous back. The book now keeps the layout chosen there and opens in it next time, as with **Page Layout** in the editor's … menu. Reported by Sudhenduahir ([#12](https://github.com/fus3r/lemma/issues/12)).
- **Two Pages Continuous** is one of Lemma's own page layouts too, beside Single Page, Continuous and Two Pages: in Page Layout, and as "Reading: Two Pages Continuous" in the command palette.

## 3.3.0 (October 2026)

**Reading, refined by Lemma's first contributor.** Six changes by Songlan Nie, who made them while reading with Lemma:

- **Gap between pages.** Pages are 8 pt apart instead of 32, and **Settings › Reading › Gap between pages** sets the gap from 0 to 32 pt. The reader, the side view and reference previews follow at once, keeping your place.
- **Reference previews** can be dragged off into a window of their own. They open at the page's width, and neither they nor the side view select the referenced label any more: on a PDF whose text layer is misaligned, the selection covered the wrong glyphs.
- **Go to** keeps your zoom and horizontal position, and scrolls sideways only when the item would be off screen. The box flashed around an equation fits the equation and its label, and a link to (15) goes to (15a)–(15c) together.
- **Citations written right after a word**, as in "and(24a)" when a PDF's text layer lost the space, are counted. "f(2)" and "exp(1)" still are not.
- The **notebook panel** has a close button, in the VS Code-style and the Classic window.
- **⌘F** puts the cursor in the find field even when the page-number field had it, and Return in the page-number field gives the keyboard back to the page.

Books are read again once after the update, since equation regions and citation counts are computed differently.

## 3.2.2 (October 2026)

**Fixed.**
- The Dock showed another Lemma icon among its recent apps for each new or changed PDF Lemma read, and after Lemma was quit and opened again: the helper that reads books took on Lemma's identity. It now runs from a background-only bundle of its own. Found and fixed first by Songlan Nie in a fork of Lemma.

## 3.2.1 (October 2026)

- **Help › Report How Lemma Read This Book…** (also in the command palette) opens GitHub's book report form with the book's title and what Lemma found in it (equations, figures, tables, statements, proofs, bibliography and index entries) already filled in: say what went wrong and submit it from your browser. Nothing is sent before you do.

**Fixed.**
- When macOS asked whether Lemma may read a library folder (in Documents, Desktop or Downloads), or a library folder sat on a disk that was waking up, Lemma stopped responding until it had an answer. Library folders are now followed in the background.

## 3.2.0 (October 2026)

**Asking, redone.** Select a passage and press ⌘K: in the VS Code-style window, Ask now opens as an editor widget under the passage, in your theme's colours, the way VS Code's inline chat opens under a line. It shows the passage, your question and the kind of help, then everything sent with it, each item with its checkbox and the cited equations as thumbnails, and finally the assistant and how to send. In the Classic window the popover keeps its size: the passage and the context list are no longer squeezed out of sight.

- **Send now** or **Review first** (ChatGPT Web) replace “Ask and save” and “Review in Lemma” in quick questions; Review first prepares the question in Lemma's ChatGPT page for you to check and send.
- The **Questions** panel lists every question asked since Lemma opened. A failed or cancelled question can be asked again with one click (**Ask Again**), with the same text and images, to the same note.
- The question names the printed page as well as the PDF's, the book's authors when the PDF knows them, and puts the passage and your notes before the question. **Explain** asks the assistant to fill in the steps the book leaves out (“it is not hard to show”), and the command-line tools and API keys no longer forbid ordinary mathematics that the pages don't show.

**The Assistants window, redrawn** to look like the rest of the workbench, in your theme's colours. A title bar holds the **Questions** and **Connections** tabs and **Continue Reading**; the questions are listed on the side bar's colour, each with a spinner, a check or a cross; the selected one shows its state on one line with the next action beside it, then ChatGPT's page from edge to edge, with VS Code's progress line along its top while it answers. Connections lists the six assistants with their icon and whether each is ready, and the Chrome companion's setup in two steps. **Prepare your question** (Full Draft…) takes the same look. The Classic window keeps its Mac controls.

**Fixed.**
- A saved explanation scrolls with the trackpad and the mouse wheel: with the pointer over the explanation, the Notes inspector stopped scrolling.
- Explanations and answers take the theme's colours for text, links, code and quotes, and a displayed equation too wide for the inspector is set smaller so that it fits beside its number, which used to cover the end of the equation.
- In a theme whose focus colour is nearly invisible, such as SynthWave '84, the note's kind, its More Actions menu and the notes filter could not be seen: such controls now take the theme's button colour, made readable. The note editor's links and fields use the theme's link and input colours.
- Switching the Assistants window to Connections while ChatGPT was answering showed an empty page.
- ChatGPT Web: macOS's smart quotes changed the question while Lemma typed it (`"""` became `“”"`), so Lemma stopped with “The question could not be inserted intact”. The question stayed in ChatGPT, which shows unsent text again in every new chat, so every later question stopped with “The composer already contains a draft”. Lemma now types with substitutions off, replaces an unsent question it prepared itself, keeps any other draft and offers **Replace Draft and Ask Again**, and keeps the ChatGPT page in view after a failure.
- ChatGPT Web follows ChatGPT's October page: the composer, Send and Stop are found by their structure in any interface language, images go through the multi-file picker rather than the camera's, and **Cancel Question** stops the answer being written.
- Answers from ChatGPT Web keep their code blocks (one line per line, with the language, ready for the Lab), tables, bold and italic. A reply with code is no longer saved before it is finished.
- An answer that takes more than an hour (a long review, a slow thinking model) is still saved.

## 3.1.0 (October 2026)

**Updates inside Lemma.** **Lemma › Check for Updates…** shows what is new in a release, installs it and relaunches Lemma: no more downloading a disk image. If you agree (Lemma asks once, at its second launch), it also checks once a day, and it can download and install an update on its own when you quit (**Settings › Updates**). Updates are signed with the project's key, so Lemma installs only versions its maintainers published.

- The updating is done by Sparkle (MIT licence), listed in **Help › Acknowledgements**.
- Your choice of a daily check in Lemma 3.0 carries over.

## 3.0.0, the first public release (October 2026)

**A look of its own.** Lemma Dark and Lemma Light are the new default themes: warm graphite and paper with an olive accent, following macOS light and dark. A new icon. A new Welcome page: open a PDF, drop one, add a folder of PDFs, pick a free textbook from a shelf of covers, or continue a book where you left it. The catalog's 45 free textbooks get covers. The Lemma Tour lets new readers choose between the VS Code-style workbench and the classic Mac window. A sample book, **Least Squares in Twelve Pages**, shows what Lemma does without a PDF at hand (Help › Open the Sample Book).

**Reading.**
- Find in the book (⌘F), as in an editor, with Match Case and Match Whole Word: the matches are highlighted on the page, and ⌘G, ⇧⌘G, Return and ⇧Return move between them from where you are reading.
- PDFs open from Finder (Open With), from the Dock and from other apps.
- Books take their title from the PDF's metadata when it has a real one.
- ⌘C copies a passage as running text: the PDF's line breaks and words hyphenated across lines are joined.
- ⌥-click a reference to open it beside the page, as the hover and the peek say.
- Lemma launches, scrolls, switches books and searches faster, and does nothing while idle: no timers, polling or redraws.
- Notes follow a PDF whose file changed on disk (annotated in Preview, downloaded again), and password-protected PDFs open.

**Assistants.** OpenAI, Anthropic and Google Gemini with your own API key, stored in the Keychain, join ChatGPT, Codex and Claude Code. The command-line tools use whatever sign-in you set up, signing in happens in your browser, and ChatGPT's page loads only when you connect it.

**Lab.** **Set Up Python for the Lab…** creates a private Python environment with NumPy, SciPy, Matplotlib, SymPy and pandas. Notebooks' Python processes always stop when Lemma quits.

**Trust.** Lemma is free software (GNU GPL v3) on GitHub. **Help** has Report an Issue, Privacy and Acknowledgements; **Lemma › Check for Updates…** asks GitHub for a newer release, only when you ask or once a day if you turn it on. New readers start with two libraries, Books and Papers. Search indexing runs in Lemma's own helper at low priority and pauses on battery, in Low Power Mode and when the Mac is hot. The statistics experiments (ridge, Lasso, nearest neighbours) appear only for statistical-learning books. OCR uses your languages.

**Changed shortcuts**, because macOS takes the old ones: Save Definition is ⌥⌘S, Resume at the First “?” is ⌥⌘J, and Show What This Statement Uses is ⇧⌥⌘H.

**Fixed.**
- Two catalog books that share a title no longer download over each other.
- Equation previews no longer take in the line above in books set in 11 or 12 pt; each book is read again once, in the background, after the update.
- References a PDF links by their number only (“Theorem 1.3”, “(2.1)”) are named in full in peeks and counted with what they cite.
- Peeks and hovers stay inside the window.
- High-contrast themes now apply to menus and peeks.
- Return no longer reopens the last book in the Classic home.
- The Classic panel can't grow taller than the window.
- Lemma can no longer be stopped by a command-line tool that quits early.
- Quit works while a sheet is open.
- Close Others and Close All close at once instead of opening each book on the way, and ⌘W passes over a book whose PDF is missing.
- A damaged book file no longer hides the rest of the Library, and Lemma never overwrites it.
- Search results, links and project passages wait for their book to open before moving the page.
- Redo works for collected passages, and the Lab's processes never outlive Lemma.

## Earlier versions

- **2.5** (October 2026): the Lemma Tour shortened to six steps on your own window, with short guides for each part.
- **2.4**: the Library as an editor's tree: renames in Lemma or on disk, drag and drop, Undo.
- **2.3**: assistants inside Lemma (ChatGPT Web, Codex, Claude Code); visible highlight controls; Back and Forward on ⌥⌘← and ⌥⌘→.
- **2.2**: the first-launch Lemma Tour.
- **2.1**: libraries of watched folders, arXiv search, the Chrome companion's Quick Add; PDFs dropped beside the reader; faster minimap and saves.
- **2.0**: the VS Code-style workbench, 84 colour themes, Run and Debug for proofs, Testing for recall, the minimap, search across the library.
- **1.1**: research projects across books, a durable editor session, workbench themes and layouts, formulas read as LaTeX.
- **1.0**: derivations checked as you type, editor groups, the Problems panel, line numbers, page themes, the free textbook catalog, Find the Paper.
- **0.9**: the structure of a mathematical text: results, folded proofs, what-uses-what, the dependency map, the reading ruler, notation hovers.
- **0.8**: the Lab (Python notebooks), hover previews, the page inspector, reading progress.
- **0.7**: the workbench: command palette, tabs, breadcrumbs, split editor, panel and overview ruler.
- **0.1 to 0.6**: the reader, source-linked notes and questions, references as links, recall, OCR, drawing on your edition.
