# 🐷 Piggy Bank

A World of Warcraft addon that saves a slice of everything you earn, hides it from your bags, and makes you **smash the piggy** to get it back.

Works with **WoW Forever**, **Classic Era** (Vanilla, Hardcore, Season of Discovery) and **Retail**.

![The Piggy Bank window and floating piggy](screenshots/piggy-tab.webp)

## Features

- **Automatic savings.** Pick a rate from 0–90% and that share of every gold gain goes into the piggy.
- **Hidden gold.** Your bag money counter shows only your *spendable* gold. Hover over it for the full breakdown. Works with the default bags and **Bagnon**.
- **Choose what counts as income.** Looted gold, quest rewards, vendor sales, mailbox gold (auction sales) and everything else can each be switched on or off. Gold you pull out of a bank or get in a trade never counts.
- **Always keep some spendable.** Set an amount, like repair money, and the piggy won't save while your spendable gold is below it.
- **Savings goals.** Set up to 5 goals in gold, silver and copper, each with a progress bar. You get a raid-warning cheer when you reach one, then **Cash Out** releases exactly that amount without smashing the piggy.
- **Feed the piggy.** Drop in extra gold by hand.
- **Smash it.** Whack the piggy 3 times and confirm to release your savings. A broken piggy stops saving until you start a new one (free, one click).
- **Get scolded.** Spend into your savings and the piggy pops up to tell you off with one of 26 painfully cheesy puns.
  > *"That gold was soulbound to the piggy! BoP = Bacon on Purpose!"*
- **Spending warnings.** A ⚠ icon and tooltip flag anything that would dip into your savings at vendors (including Repair All), trainers, flight masters and the auction house. Buying auction house commodities (or clicking Bid / Buyout in Classic) pops up a heads-up before you confirm.
- **Stats.** A 7-day savings chart, this week's savings, lifetime saved, your total across all characters, goals completed and cashed out, piggies smashed, times caught raiding the piggy, and more.
- **Info bar support.** Shows your savings on Titan Panel, ElvUI DataTexts, Bazooka, ChocolateBar and other LibDataBroker displays.
- **Floating piggy.** An optional on-screen piggy showing your savings. It's off by default, and you can lock it in place.
- **Minimap button.** Click the piggy on your minimap to open the window. Drag it to move it, or hide it in Settings.

## Screenshots

| Getting scolded | Vendor warning | Bags show only spendable gold |
| --- | --- | --- |
| ![The piggy scolding you](screenshots/scold.png) | ![A vendor item flagged with a savings warning](screenshots/vendor-warning.png) | ![Bag money counter with the piggy icon](screenshots/bag-counter.png) |

| Goals | Stats | Settings |
| --- | --- | --- |
| ![Goals tab](screenshots/goals-tab.png) | ![Stats tab](screenshots/stats-tab.png) | ![Settings tab](screenshots/settings-tab.png) |

## How it works (and its limits)

WoW addons can't move or lock gold, so the piggy is a ledger. It keeps track of how much of your gold counts as savings and changes what the bag counter shows. The game will still let you spend it. You'll just hear about it.

Other addons or windows that show your gold will still show your real total.

## Installation

1. Download this repo (**Code → Download ZIP**) and extract it.
2. Make sure the folder is named `PiggyBank`. Rename it if it's `PiggyBank-main`.
3. Put it in your AddOns folder:
   - **WoW Forever:** `World of Warcraft/_forever_/Interface/AddOns/`
   - **Classic Era:** `World of Warcraft/_classic_era_/Interface/AddOns/`
   - **Retail:** `World of Warcraft/_retail_/Interface/AddOns/`
4. Restart WoW or type `/reload`.

If the AddOns list says Piggy Bank is out of date, tick **Load out-of-date AddOns**.

## Usage

Open the piggy any of these ways:

- Type `/piggy`.
- Click the piggy button on your minimap, or the addon menu button next to it.
- Go to **Esc → Options → AddOns → Piggy Bank**.
- Click your bag gold counter or the floating piggy.

Every setting is in the window, across the **Piggy**, **Goals**, **Stats** and **Settings** tabs. Slash commands are optional:

| Command | What it does |
| --- | --- |
| `/piggy` | Open or close the piggy window |
| `/piggy rate 25` | Save 25% of income (0–90) |
| `/piggy goal 500 New Mount` | Add a goal of 500 gold |
| `/piggy feed 10` | Put 10 gold in by hand |
| `/piggy keep 5` | Always keep 5 gold spendable (`0` turns it off) |
| `/piggy widget` | Show or hide the floating piggy |

Savings are stored **per character**. The Stats tab also shows your total across all characters.

## Translations

Piggy Bank can be translated into any language the game supports. See [TRANSLATING.md](TRANSLATING.md) for how. Partial translations are welcome.

## Bugs and ideas

Open an issue on GitHub. The bug report form asks for your game version and any Lua error, which helps a lot.

## License

Public domain. See [LICENSE](LICENSE).
