# DQM: The Dark Prince - Monster tree generator

A PowerShell utility that turns Game8's Dragon Quest Monsters 3 synthesis data and MetalKid's field listings into shareable Markdown. Feed it a monster name and it builds a mermaid-powered family tree, complete with portraits, color-coded statuses, and scoutable location notes.

## Highlights

- Pulls the official Game8 structural mapping dataset for Dark Prince monsters.
- Scrapes each monster page for number, family, rank, talents, and portrait imagery.
- Cross-references MetalKid's lookup/locations API to flag scoutable monsters and list their known spawn spots.
- Builds a mermaid `graph LR` diagram with color-coded nodes for the target monster, scoutable parents, duplicates, and embedded 96x96 artwork.
- Writes a ready-to-publish Markdown file alongside an `images/` folder of cached artwork and family crests, while caching third-party packages and JSON data locally for fast repeat runs.

## Example Output

![Example](assets/example.png)

## Prerequisites

- PowerShell 7+ (Windows PowerShell 5.1 also works but 7+ is recommended).
- Internet access to reach Game8, dev.metalkid.info, and NuGet (the script downloads HtmlAgilityPack on first run).
- Permission to create `.cache/` and `images/` directories under the chosen output path.
- Visual Studio Code is recommended for previewing Markdown. Install the `Markdown Preview Mermaid Support` extension to display Mermaid diagrams correctly.

## Usage

Run the script from the repository root (or anywhere you have the `.ps1` file):

```powershell
pwsh .\Dqm3-GenerateMonsterTree.ps1 -MonsterName "Slime Knight" -OutputDirectory .\output -Overwrite
```

The generated Markdown includes a synthesis graph and a `Scout locations` section populated from MetalKid data whenever the parents are scoutable.

### Parameters

- `-MonsterName` *(required)*: Exact monster name as listed on Game8.
- `-OutputDirectory`: Destination for the Markdown file and `images/` folder. Defaults to the current directory.
- `-Overwrite`: Allow regeneration when the target Markdown file already exists.

### What you get

- `<OutputDirectory>/<monster-name>.md` containing monster metadata, a color-coded mermaid synthesis tree, and scout location bullet lists.
- `<OutputDirectory>/images/` with 96x96 portrait JPGs plus any bundled family crests from `assets/images` (copied over on each run).
- `.cache/` beside the script storing HtmlAgilityPack, the Game8 mapping JSON, and MetalKid lookup/location caches (deleted automatically when refreshed).

## Tips

- Monster names must match Game8's capitalization and punctuation. If the script cannot locate the monster, verify the spelling on their site.
- Delete `.cache/dqm3_mapping.json` to force a fresh download of the Game8 mapping dataset on the next run.
- Delete `.cache/metalkid_locations.json` or `.cache/metalkid_monsters.json` to refresh scout location data if MetalKid updates their listings.
- Mermaid diagrams render natively on platforms like GitHub and GitLab; other viewers may need a Mermaid plugin.

## Credits

- Script vibe-coded by Codex.
- Special thanks to [Game8.co](https://game8.co/games/DQM-Dark-Prince).
- [MetalKid](https://dev.metalkid.info/) for the DQM3 location and lookup APIs.
- HtmlAgilityPack project for the HTML parser.

## License

Released to the public domain under the [Unlicense](LICENSE).
