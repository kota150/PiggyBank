<!-- Paste everything below this line into the CurseForge project description (Markdown mode). -->

# Piggy Bank

**Saving gold is hard. Smashing a piggy bank is fun.**

Piggy Bank automatically squirrels away a slice of everything you earn, hides it from your bags, and makes you **smash the piggy** to get it back. Spend into your savings and the piggy will let you know, with a truly cheesy pun.

Works with **Classic Era** (Vanilla, Hardcore, Season of Discovery), **WoW Forever** and **Retail**.

![The Piggy Bank window](https://raw.githubusercontent.com/kota150/PiggyBank/main/screenshots/piggy-tab.webp)

## Features

- **Automatic savings.** Pick a rate from 0–90% and that share of every gold gain goes into the piggy.
- **Hidden gold.** Your bag money counter shows only your *spendable* gold. Works with the default bags, **Bagnon** and **Baganator**.
- **Choose what counts as income.** Looted gold, quest rewards, vendor sales, auction sales and everything else can each be switched on or off. Bank and trade gold never counts.
- **Always keep some spendable.** Set an amount, like repair money, and the piggy won't save below it. Great for Classic and Hardcore.
- **Savings goals.** Up to 5 goals in gold, silver and copper, with progress bars, a cheer when you reach one, and a **Cash Out** button that releases just that goal's gold.
- **Spending warnings.** Vendors, Repair All, trainers, flight masters and the auction house flag anything that would dip into your savings.
- **Smash it.** Whack the piggy 3 times to release your savings. A broken piggy stops saving until you start a new one (free, one click).
- **Get scolded.** Spend your savings and the piggy pops up with one of 26 painfully cheesy puns.
  > *"Hogger is disappointed in you. And Hogger eats people."*
- **Stats.** A 7-day savings chart, your total across all characters, lifetime saved, goals cashed out, piggies smashed, times caught raiding the piggy, and more.
- **Info bar support.** Titan Panel, ElvUI DataTexts, Bazooka, ChocolateBar and other LibDataBroker displays.
- **Translatable.** Want Piggy Bank in your language? See TRANSLATING.md on GitHub.
- **No typing required.** A minimap button opens the window, and every setting is in there. Slash commands are there if you want them.

![Getting scolded](https://raw.githubusercontent.com/kota150/PiggyBank/main/screenshots/scold.png)
![Vendor warning](https://raw.githubusercontent.com/kota150/PiggyBank/main/screenshots/vendor-warning.png)

## Usage

Type `/piggy`, click the piggy on your minimap or your bag gold counter, or find **Piggy Bank** in **Esc → Options → AddOns**.

| Command | What it does |
| --- | --- |
| `/piggy` | Open or close the piggy window |
| `/piggy rate 25` | Save 25% of income (0–90) |
| `/piggy goal 500 New Mount` | Add a goal of 500 gold |
| `/piggy feed 10` | Put 10 gold in by hand |
| `/piggy keep 5` | Always keep 5 gold spendable (`0` turns it off) |
| `/piggy widget` | Show or hide the floating piggy |

## Good to know

Addons can't lock gold, so the piggy is a ledger: the game will still let you spend your savings. You'll just hear about it.

Savings are stored per character, and the Stats tab shows your total across all characters.

## Feedback and translations

Found a bug or have an idea? Open an issue on [GitHub](https://github.com/kota150/PiggyBank/issues). The bug form asks for your game version and any Lua error.

Want Piggy Bank in your language? See [TRANSLATING.md](https://github.com/kota150/PiggyBank/blob/main/TRANSLATING.md). Partial translations are welcome.
