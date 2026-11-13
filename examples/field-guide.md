# A field guide to the Northern Marches

An example document for `pretty-tables-for-markdown-mode`. The guild,
the places and the creatures are invented; the table is shaped like real
ones, where most cells link to other documents. It is wider than
`fill-column`, its cells hold one or two links each, and one cell uses
`<br>` to start a new line. The second table holds LaTeX formulas, which
`latex-to-svg-for-markdown-mode` draws as images.

The linked files are not included, so the links do not open anything.
They are not needed to show the problem: with the file names in the
links, the raw rows of the table cannot be read, and this package draws
them as a table that can.

## Creatures of the Marches

| Creature | Habitat | Guide entry | Last sighting |
|---|---|---|---|
| Ash dragon | Volcanic caves above the [Cinder Pass](atlas/regions/cinder-pass.md#caves) | [Ash dragons and their hoards](bestiary/dragons.md#ash-dragon); [Fire safety for travellers](handbook/fire.md#dragons) | Spring 1123, by the ranger [Ilse Morrow](people/rangers.md#ilse-morrow) |
| Marsh kraken | Deep pools of the [Sallow Fens](atlas/regions/sallow-fens.md#pools) | [The kraken of fresh water](bestiary/sea-beasts.md#marsh-kraken) | A capsized ferry at [Reedmouth](atlas/towns/reedmouth.md#harbour), autumn 1122 |
| Griffin | Cliff nests on the [Hollow Spires](atlas/regions/hollow-spires.md#cliffs) | [Griffins](bestiary/winged.md#griffin); [Sketch](https://example.org/field-guide/griffin.png) | Three nests counted in summer 1123 |
| Bog light <br>*The guild files it under weather, not creatures. Keep to the marked path at night.* | Peat bogs at dusk | [Lights over the bog](bestiary/spirits.md#bog-light); [Night travel](handbook/travel.md#after-dark) | Every clear night; the guild stopped counting in 1120 |
| Basilisk | Abandoned mines of [Greyhallow](atlas/towns/greyhallow.md#mines) | [Basilisks, and how to look away](bestiary/reptiles.md#basilisk) | Winter 1121, when two miners were turned to stone |
| Phoenix | Unknown; it is seen only while it burns | [The phoenix question](bestiary/winged.md#phoenix); [Lecture notes](https://example.org/guild/lectures/phoenix/) | Once, in 1098, over the old capital |
| Mimic | Any dungeon with a treasure chest in it | [Mimics](bestiary/oddities.md#mimic); [Opening chests safely](handbook/dungeons.md#chests) | Last week, in the guild's own storeroom |
| Stone golem | The gate of the ruins of [Old Varn](atlas/ruins/old-varn.md#gate) | [Golems and their makers](bestiary/constructs.md#stone-golem) | Standing at the gate, as it has for 300 years |

## From the guild's spell book

| Spell | Formula | Effect |
|---|---|---|
| Ward of the cold circle | $\oint_{\partial C} \vec{q} \cdot \hat{n}\,\mathrm{d}\ell = 0$ | No heat crosses a circle drawn round a camp. Taught with [Fire safety for travellers](handbook/fire.md#dragons). |
| Counting charm | $\int_{\text{dusk}}^{\text{dawn}} \lambda(t)\,\mathrm{d}t$ | Counts the lights over a bog in one night. The guild stopped casting it in 1120. |
| Waking word | $\frac{\mathrm{d}x}{\mathrm{d}t} > 0$ | Wakes a stone golem. Said at the gate of [Old Varn](atlas/ruins/old-varn.md#gate) every spring; the golem has not moved. |
