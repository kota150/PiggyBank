-- Translations. English is built in: every piece of text in the addon is looked up by its
-- English wording, and anything without a translation shows in English.
--
-- To translate, copy Locales/_template.lua to Locales/<locale>.lua (for example deDE.lua),
-- fill in the translations, and add the file to the TOCs right after Locales.lua.
-- See TRANSLATING.md for details.

local _, ns = ...

ns.L = setmetatable({}, {
    __index = function(t, key)
        t[key] = key
        return key
    end,
})

-- One of these pops up (at random) when you spend into your savings. Cheese is mandatory.
-- Translators can replace the whole list; puns don't have to be literal translations.
ns.SCOLDS = {
    "Gold doesn't grow on Peacebloom, you know!",
    "You just rolled Need on your own savings. NINJA LOOTER!",
    "Your savings took more damage than a tank with no healer.",
    "Hogger is disappointed in you. And Hogger eats people.",
    "You are not prepared... for retirement!",
    "That gold was soulbound to the piggy! BoP = Bacon on Purpose!",
    "Pork chop? More like WALLET CHOP.",
    "Stop! HAM time. Put. It. Back.",
    "Your spending just pulled aggro from the whole bank.",
    "Bacon me crazy, you spent the savings!",
    "Swine and dine all you want, but not with MY gold.",
    "Even a murloc saves better. Mrglglgl... *disappointed gurgle*",
    "Zug zug? More like ZUG ZUG WHERE'D THE GOLD GO.",
    "Achievement unlocked: Broke-en Hero.",
    "Your piggy has been Sapped. Emotionally.",
    "That's not a cooldown, that's a MELTDOWN.",
    "Wipe on the budget raid! Everybody run back.",
    "Lok'tar ogar? More like Lok'tar BROKE-gar.",
    "Do you even know what 'savings' means, or are you just here for the loot?",
    "You've been hit by Mortal Strike: savings healing reduced by 100%.",
    "Oink oink means NO NO.",
    "Your financial advisor is a pig and even HE is judging you.",
    "This is why we can't have nice mounts.",
    "Hamstring! You've crippled your savings!",
    "The Lich King hoards better than you. And he's FROZEN.",
    "Ham-ateur move, champion. Ham-ateur move.",
}

-- Pops up before an auction house purchase that would dip into savings.
ns.HEADS_UPS = {
    "Whoa there, big spender! This purchase raids the piggy.",
    "Incoming savings damage! Interrupt now?",
    "The piggy is watching. And sweating.",
    "Hold your horses! Unless you're buying a horse. Then REALLY hold them.",
    "This one's coming out of the piggy. Are you sure, champion?",
    "Pull! Wait, no, don't pull. This dips into your savings.",
    "Squeal of disapproval incoming in 3... 2...",
}
