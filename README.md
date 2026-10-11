# TransmogKit - Auction Source Finder

An **Expansions** tab next to Buy / Sell / Auctions. It covers the whole
window (search bar and bottom bar included, like a real tab) with:

- **Collapsible categories** on the left, mirroring the native Browse
  tab's menu (Weapons > One-Handed/Two-Handed/..., Armor > Plate > Head/
  Shoulder/..., Miscellaneous > Neck/Finger/..., and so on). Click a node
  to load it and expand its sub-menu; click it again to collapse. Opening
  one closes its siblings. Each click fires a real
  `C_AuctionHouse.SendBrowseQuery` for that node's filters.
- **A top row of filters** to narrow the results: a Name box, an
  **Uncollected Only** toggle, a **Rarity** dropdown (tick as many as you
  like; stays open) and an **Expansion** dropdown (pick one; closes when
  you do, and the current expansion is tagged "(current)"). Only one
  dropdown is open at a time.
- **Price / Name / Available** results below, with item icons and
  quality colors.

## Using it

- **Hover** a row: the normal item tooltip.
- **Ctrl-click**: dressing-room preview. **Shift-click**: link to chat.
  (Both go through Blizzard's own `HandleModifiedItemClick`.)
- **Click**: opens the item's real buy page (bid/buyout list with
  Blizzard's own Buyout button) via `AuctionHouseFrame:SelectBrowseResult`,
  the same call Blizzard's own browse rows make. The buy itself is done by
  Blizzard's secure button, not by any purchase code in this addon.

## Why expansion filtering is client-side

Blizzard's "Current Expansion Only" checkbox only supports the newest
expansion; there is no "any expansion" version to reuse. So this reads
the `expansionID` that `GetItemInfo()` returns for each item and filters
the loaded results.

## Troubleshooting

`/tkauction tabs` prints whether `AuctionHouseFrame.AuctionsTab` and
`SelectBrowseResult` exist on your client and lists labelled buttons,
useful if the tab lands in the wrong spot.

`/tkauction on` / `/tkauction off` toggles the module.

## Filters: Uncollected Only + Rarity

- **Uncollected Only** is a toggle button next to the Name box.
- **Rarity** is a collapsing menu: click it, tick as many rarities as you
  like (Poor through Artifact), and it stays open while you tick. "Clear"
  goes back to all rarities. The button summarizes your picks.
- Both are real server-side filters (the same `Enum.AuctionHouseFilter`
  values Blizzard's own Filter dropdown uses), so changing one re-sends
  your current category's query. They're saved between sessions.
- `/tkauction filters` lists which filter names your client actually has.

## Icon

`Media/icon.tga` is the pixel-art balance scale shown next to the addon in
the AddOns list (set with `## IconTexture:` in the .toc, supported since
10.1.0). It's a 64x64, 32-bit uncompressed TGA with alpha, which meets the
client's rules for custom textures (power-of-two size, at most 1024). If the
icon doesn't show right after updating, `/reload` should pick it up; a full
client restart definitely will.

## Searching by name

The **Name** box does two things:

- **Press Enter** to run a real Auction House search for that text, using
  your Rarity / Uncollected / Expansion filters. With no category selected
  it searches every category; with one selected it searches within it
  (like Blizzard's own search bar). Picking a category afterwards keeps the
  searched name, and clearing the box then pressing Enter goes back to the
  plain category.
- **Just typing** narrows results that are already loaded, instantly. There
  is nothing loaded until a category or a search has been sent, which is why
  typing alone on a fresh tab shows "Press Enter to search".

Text the Auction House has already searched for is not re-filtered locally,
because it matches names its own way (partial words and so on) and a
stricter local check would hide valid results. Each new Auction House visit
starts with an empty Name box.

## Sorting

- **Rarity** (new column next to Available, in each item's colour). By
  default the list is sorted **Epic first**, then Rare, Uncommon, Common,
  Poor, with the cheapest first inside each rarity. Click the **Rarity**
  header to flip it (Poor first).
- **Price**: click the **Price** header for cheapest to most expensive;
  click again for most expensive first.
- **iLvl** (item level column, between Rarity and Available): click the
  **iLvl** header for highest item level first, click again for lowest
  first. Ties go to the better rarity, then the cheaper price. Items with
  no item level (consumables, materials) always sort last. The level comes
  straight from the Auction House's own item key, since it lists the same
  item at different item levels as separate rows, which is also why the
  column helps tell identical names apart.
- The active column shows `^` (ascending) or `v` (descending). Your choice
  is remembered between sessions, and clicking a header jumps back to the
  top of the list. Items whose rarity hasn't loaded yet always sort last.
- Once you've picked a single expansion the "(Expansion)" tag on each row is
  dropped, since it would be the same on every line, which leaves more room
  for the item name.

## Back button

Blizzard's buy page has its own **Back** button. If you opened that page
from the Expansions tab, Back now brings you **back to the Expansions tab**
with your category, filters and scroll position where you left them (if
Blizzard cleared its results on the way back, the last query is re-sent).
If you opened the buy page some other way, Back behaves normally, and
clicking one of Blizzard's own tabs or closing the Auction House cancels
the return.

Turn it off in Settings > AddOns > Auction Source Finder, or with
`/tkauction back off` (`back on` to re-enable). `/tkauction tabs` reports
how many Back buttons were found and hooked.

## Loading speed and item names

A browse result only carries an item ID; names, expansion and quality need
the client to load each item. So the list:

- requests every item's data in **one batch** the moment results arrive,
  and redraws the instant data comes back (`GET_ITEM_INFO_RECEIVED`,
  `ITEM_DATA_LOAD_RESULT`, `ITEM_KEY_ITEM_INFO_RECEIVED`);
- **holds a row back until its real name is ready**, so you don't see
  "item 12345" placeholders. The status line says how many are still
  loading. In the All view a name from the Auction House's own item info is
  enough; filtering by expansion waits for the full item data;
- gives up on an item if the server reports it has no data, or after 6
  seconds, and shows it with a fallback name rather than hiding it forever
  (some item IDs never load);
- asks for the next batch of a large category immediately, instead of
  waiting for a timer;
- only draws the rows that fit on screen and refills them as you scroll,
  so a category with thousands of items stays fast.

## Crafting-quality icons

Items with a profession crafting tier show that icon right after the name.
The tier NUMBER comes from `C_TradeSkillUI.GetItemReagentQualityByItemInfo`
/ `GetItemCraftedQualityByItemInfo`. Which ICON goes with it differs by
expansion (Midnight's two sellable qualities are silver and gold; older
content was bronze/silver/gold), so the addon doesn't map numbers to icons
itself. Per item it asks Blizzard, in order: the icon markup in the item's
own link, the item's tooltip data, Blizzard's `Professions.GetIconForQuality`
helper, and only then guessed names (Midnight-style first). Every icon name
is checked with `C_Texture.GetAtlasInfo` first, and if nothing resolves the
row shows a small `[T2]` tag rather than a wrong icon.

`/tkauction quality <itemID>` shows the detected tier, what each stage
found, and which icon was used.

## Current expansion by default

Like Blizzard's "Current Expansion Only", the tab starts on the **current
expansion** (Midnight, and it follows future expansions automatically)
every time you open the Auction House. Pick "All" or any other expansion
whenever you like.

- While the current expansion is selected, the addon also sends Blizzard's
  own server-side "Current Expansion Only" filter with the query, so the
  server returns far less data. Other expansions are filtered on this side.
- If you'd rather start on All: Settings > AddOns > Auction Source Finder,
  or `/tkauction start all` (`/tkauction start current` to switch back).
- `/tkauction expansion` shows which expansion was detected as current and
  how.

## Opens first

When you open the Auction House, the Expansions tab opens automatically
(and starts with a clean selection, since Blizzard clears its own results
on close). Turn it off in Settings > AddOns > Auction Source Finder, or
with `/tkauction first off` (`first on` to re-enable). Clicking any of
Blizzard's own tabs switches to it as usual.

## Categories: how they're built

The addon mirrors Blizzard's own `AuctionCategories` table live (name,
`{classID, subClassID, inventoryType}` filters, sub-categories), so the
menu matches the native one and follows patches automatically. If that
table can't be found it falls back to a built-in approximation.
`/tkauction cats` shows which one is in use. On login into the AH the
addon also prints a one-line "Categories: ..." message saying the same.

Large categories load in batches; the status line says "(loading more...)"
while the addon keeps asking Blizzard for the rest
(`C_AuctionHouse.RequestMoreBrowseResults`), so expansion filtering covers
the whole category, not just the first batch.
