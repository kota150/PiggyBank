# Translating Piggy Bank

Thanks for helping! Piggy Bank shows every piece of text in English unless a translation exists, so partial translations are welcome. Anything you skip simply stays in English.

## How to add a language

1. Copy `Locales/_template.lua` to `Locales/<locale>.lua`, for example `Locales/deDE.lua`.

   | Language | Locale |
   | --- | --- |
   | German | `deDE` |
   | French | `frFR` |
   | Spanish (Spain) | `esES` |
   | Spanish (Latin America) | `esMX` |
   | Portuguese (Brazil) | `ptBR` |
   | Italian | `itIT` |
   | Russian | `ruRU` |
   | Korean | `koKR` |
   | Chinese (Simplified) | `zhCN` |
   | Chinese (Traditional) | `zhTW` |

2. In your new file, change `"xxXX"` on the `GetLocale` line to your locale.
3. Translate the **right-hand side** of each line. Leave the left side (the English text in `L["..."]`) exactly as it is, since that's how the addon finds your translation.
   ```lua
   L["Spendable"] = "Ausgebbar"
   ```
4. Delete any lines you don't want to translate.
5. Add your file to all three TOC files (`PiggyBank.toc`, `PiggyBank_Vanilla.toc`, `PiggyBank_Forever.toc`), on the line right after `Locales.lua`:
   ```
   Locales.lua
   Locales\deDE.lua
   PiggyBank.lua
   ```
6. Open a pull request, or attach the file to an issue on GitHub.

## Things to keep as they are

- **`%s` and `%d`** are placeholders for amounts and numbers. Keep the same number of each, in the same order.
- **`%%`** shows a single `%` sign. Keep it doubled.
- **`|cffffd100` ... `|r`** colours text. Keep both parts around the same words.
- **`\n`** starts a new line.

## The puns

The scold messages and auction house warnings are lists at the bottom of the template (`ns.SCOLDS` and `ns.HEADS_UPS`). You can replace each whole list with your own. They don't need to be literal translations. Jokes that work in your language are better, and the cheesier the better. 🐷

## For maintainers

After changing any text in `PiggyBank.lua`, regenerate the template:

```
python3 tools/make_locale_template.py
```
