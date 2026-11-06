# Changelog

All notable changes to Piggy Bank are listed here.

## [1.4.0] - 2026-11-04

### Added
- **Choose what counts as income.** Looted gold, quest rewards, vendor sales, mailbox gold (auction sales) and everything else each have their own switch in Settings.
- **Always keep some spendable.** Set an amount (like repair money) and the piggy won't save while your spendable gold is below it. Also `/piggy keep 5`.
- **Cash out goals.** When a goal is reached, a **Cash Out** button on the Goals tab releases exactly that amount without smashing the piggy.
- **Savings history.** The Stats tab has a 7-day chart and a "Saved this week" total.
- **All characters.** The Stats tab and tooltips show your combined savings across every character. Hover the row for a per-character list.
- **Baganator support:** Baganator's backpack and bank gold shows only spendable gold too, with the piggy's numbers added to its gold tooltip. Other characters' bags are left alone.
- **Info bar support** for Titan Panel, ElvUI DataTexts, Bazooka, ChocolateBar and other LibDataBroker displays.
- **Translation support.** All text can now be translated. See TRANSLATING.md.
- A setting to turn off the login message.
- Bug report and feature request forms on GitHub.

### Changed
- The Settings tab now scrolls, to fit the new options.
- "Count mailbox gold as income" is now one of the income switches. Your old choice carries over.

## [1.3.0] - 2026-11-02

### Added
- **Minimap button.** A piggy on the edge of your minimap: click to open the piggy, drag to move it. It's on by default, and you can hide it with **Show the minimap button** in Settings.
- A login message so you know how to find the piggy: use `/piggy` or click the gold in your bags. OINK!

### Changed
- **Starting a new piggy is clearer.** After you smash the piggy, every message now says exactly what to do: open `/piggy` and click **Start a New Piggy**. It's free, no gold needed.
- "Broken" piggies are now called **smashed** everywhere, to match the SMASH! button.
- Tooltips, the floating piggy and the Stats tab now tell you how to start a new piggy instead of just saying it's broken.
- Updated for Retail 12.1.7 and WoW Forever 1.60.1.

## [1.2.0] - 2026-10-31

### Added
- Warnings at vendors and trainers: a ⚠ icon and tooltip flag anything that would dip into your savings, including Repair All.
- Flight path warnings in the destination tooltip.
- Auction house warnings: a ⚠ icon on item buyouts, and a pop-up heads-up (with its own set of puns) before you confirm a commodity purchase.
- All spending warnings share one setting: **Warn me before I spend savings**.
- **Bagnon support:** Bagnon's money display shows only spendable gold too. Other characters' bags are left alone.
- **Classic Era support** (`PiggyBank_Vanilla.toc`): fallbacks for window parts older clients lack, the older bank/trade/mail/trainer events, an Interface Options entry, and warnings on the classic auction house's Bid and Buyout buttons.

### Changed
- Retail TOC interface version set to 120105, Classic Era to 11509.

### Fixed
- Window tabs now fit their labels (they were cut off in Classic).
- Header lines no longer run underneath the goal count and savings rate.
- The savings rate slider no longer touches the + button.

## [1.1.0] - 2026-10-30

### Added
- Redesigned `/piggy` window in Blizzard style, with **Piggy**, **Goals**, **Stats** and **Settings** tabs.
- Every setting can be changed in the window. Slash commands are now optional.
- Gold / silver / copper display for savings and spendable gold.
- Gold / silver / copper inputs for goals and for feeding the piggy.
- Savings rate slider with − / + buttons and mouse-wheel support.
- Stats tab: lifetime saved, income tracked, biggest deposit, goals completed, piggies smashed, times caught raiding the piggy, and more.
- New settings: lock the floating piggy, reset its position, turn scold pop-ups on or off, turn sounds on or off.
- Entry in **Esc → Options → AddOns** and in the minimap addon menu.
- WoW Forever support (`PiggyBank_Forever.toc`).

### Changed
- The floating piggy is now **off by default**.
- When you spend your savings, the piggy pops up with a random cheesy pun (26 of them), wiggles, and hides again after 8 seconds unless it's set to always show.

## [1.0.0] - 2026-10-30

### Added
- First release.
- Automatically saves a percentage (0–90%) of all gold you earn.
- Bag money counter shows only spendable gold.
- Bank, warband bank, guild bank and trade gold isn't counted as income. Mailbox gold is optional.
- Up to 5 savings goals with progress bars and a cheer when you reach one.
- Feed the piggy by hand.
- Whack the piggy 3 times to smash it and release your savings.
- Floating piggy with savings tooltip.
