# Changelog
## Unreleased
- **Changed: the "about to run out" warning is per ability now, never inherited.** Its slider sits
  directly under the checkbox it gates, on the Texture tab and the Sound tab. All abilities' own
  copy is gone, so its General tab is just "Only in combat".
- **Changed: clearer tooltips for the five moments** (suggested, ready, used, active, about to
  expire) on the Texture, Sound and Screen-edge tabs, saying what each one actually shows.
- **Changed: "Fade with" reads Nothing / Cooldown / Buff**, with the explanation moved into its
  tooltip.
- **Changed: Size on the Texture tab now runs 16-512**, and defaults to 48 with your own icon or
  200 with a picked texture -- switching between them only moves a size you have not touched
  yourself.
- **Changed: "Move This Texture" is now "Move texture"**, moved to the top of the Texture tab,
  directly under the switch, so you can judge a texture at its real size before touching anything
  else about it.
- **New: a Blend mode on the Texture tab**, Opaque or Glow, the same two WeakAuras offers. Glow adds
  the texture's light to what is behind it, which is what aura art is drawn for. Default Opaque.
- **Fixed: an ability's settings follow every rank of the spell.** Adding a rank of an ability
  already on the Abilities list -- by id, by name, or from the spellbook -- selects that same row
  instead of creating a second one, and its stored id follows the highest rank you have learned as
  you level. `/elm debug state` now lists every ability's name, stored id and current spellbook id,
  so a mismatch is visible at a glance.
- **Changed: Choose… opens the texture picker on a clear screen.** Pressing Choose… on an ability's
  Texture tab now does what "Move This Texture" does as well -- the configuration window steps
  aside, the Move toolbar appears and the texture itself is left on screen -- and opens the picker
  over that instead of over the window. Okay or Cancel closes the picker and leaves you on the clear
  screen to keep dragging and resizing; Done on the toolbar (or Escape) brings the window back on
  the tab you were reading.
- **Changed: a texture sits in the centre of the screen until you drag it.** The "Position" dropdown
  and the shared indicator row are gone, along with "Position the Indicators" on All abilities ›
  General. Every texture starts in the middle of the screen and "Move This Texture" stores where you
  drop it; two textures you have not moved will overlap, which is deliberate -- drag one.
- **Changed: no Preview button; the texture is live while its tab is open.** Open an ability's
  Texture tab and its texture stands on screen exactly as configured, following the size, colour,
  opacity and picture as you change them. It goes when you leave the tab, pick another ability,
  close the window or switch the texture off.
- **New: a Reset button on the Texture tab**, at the right-hand end of the Move row and confirm-gated,
  puts the picture, size, colour, opacity, moments, fade and position back the way they shipped. The
  texture stays switched on.
- **Changed: unticking "Show a texture for this ability" greys the whole tab**, so it reads as one
  switch and its settings rather than a page of controls that change nothing.
- **Changed: the picker's first category is called "Shapes"** rather than "Elmira Shapes".
- **Changed: the "From your spellbook" list shows each spell's id after its name**, e.g.
  `Exorcism (415073)`, so two rows that read the same can be told apart. It is still sorted by name.
- **New: a visual texture picker.** An ability's Texture tab now asks one question -- "Use this
  ability's own icon" -- and, when you untick it, shows the file it draws with a **Choose…** button
  beside it. Choose… opens a window of pictures: Elmira's own shapes, Blizzard's icons, runes,
  beams, sparks, PvP emblems and target markers, and every texture your LibSharedMedia packs
  provide, with a category dropdown and a search box. Clicking a picture puts it on screen straight
  away so you can judge it at its real size; Cancel puts back what you had. If WeakAuras is
  installed, its shapes and all 145 PowerAuras textures are offered too -- by path, from your own
  copy of WeakAuras, and only while it is installed. The Source and Shape dropdowns are gone; typing
  a path still works, in the same box.
- **New: the bar you get while moving a texture is a toolbar.** Drag an indicator and the bar at the
  top of the screen carries that ability's icon and name, a Texture button that opens the picker,
  Size, Colour and Opacity -- so you can try a texture out on a clear screen without the
  configuration window in the way. Everything you change there is the same setting the Texture tab
  holds.
- **New: a texture that needs an addon you do not have says so.** A picture from WeakAuras' folder
  draws Elmira's ring on a character without WeakAuras, and both the Texture tab and
  `/elm debug textures` now say why instead of leaving it looking like it works. Nothing is reset.
- **Changed: the default glow style is Proc, the game's own proc glow.**
- **New: an ability's glow has its own "Show the glow" schedule** (Always / in combat or when you
  have a target / in combat only), on the Glow tab, independent of the queue strip -- a hidden strip
  no longer silences a glow set to Always, and a visible strip no longer forces one set to In combat
  only.
- **New: the strip's first icon can glow too.** "Glow the first icon on the strip", on the Queue
  page, is off by default; switched on, it lights in the suggested ability's own colour and style,
  on the same schedule as the action-bar glow and independent of "Enable action bar glow".
- **Changed: All abilities now sets only General and Glow.** Texture, Screen-edge, Sound and
  Announcement are set per ability only; the "Warn me when its buff has N seconds left" slider moved
  onto the Sound and Texture tabs, right after the moment it guards, and All abilities' own copy
  stays on General as the shared default.
- **Fixed: the options window can no longer come back without its header.** Every time the window is
  put back on screen — after Position the Strip, Move This Texture or any other Move mode — its
  full-width drag bar and the version text on the left are re-applied, so a window that lost them
  while it was out of the way comes back dressed instead of staying stripped until you close and
  reopen it. A failure to size or place the window no longer takes the header down with it either.
  `/elm debug state` now says `window chrome: dressed` or `stripped`, so a missing header can be
  reported without a screenshot.
- **Changed: a texture fades with its own cooldown or buff instead of sweeping.** "Fade with", below
  the five moments on an ability's Texture tab, sets the texture's opacity to how much of that
  ability's cooldown is left recovering or how much of its buff remains — a buff starts fully lit
  and fades out, a cooldown starts faint and brightens as it comes back. Static (the tab's own
  Opacity) when neither is picked, and `/elm debug textures` reports the current fraction rather
  than leaving you guessing whether it is working.
- **Changed: adding an ability by ID or name now behaves like a WeakAuras trigger box.** Press Enter
  to resolve it — an icon appears beside the box and it now reads "20930 (Holy Shock)" — and nothing
  is stored yet. Add, or Enter again, registers it (selecting it instead if it is already on your
  list) and clears the box; anything that does not resolve just clears in silence.
- **Changed: the Rotations page no longer lists playstyles in the left menu.** Every playstyle and
  every rotation of your own is a card on the Rotations page, and clicking one shows it in the panel
  below the cards; the left menu keeps only Builder and Share under Rotations.
- **Changed: the Glow, Peripheral cues and Cue sounds pages are gone.** Every cue an ability can
  make — its glow, its texture, its screen edge, its sounds, its announcement — is set on that
  ability, under Abilities. "Play ability sounds", the one switch that silences all of them at once,
  is a panel on Notifications instead of a page of its own.
- **Changed: the Profiles page says that ability settings are per character** and do not switch with
  the profile, and points at Abilities › Share for copying them.
- **Changed: `/elm import` says how many abilities' settings came with the rotation**, the way the
  options window already did.
- **Fixed: on a class Elmira ships no data for, an ability you registered yourself now glows on your
  action bars, shows its real tooltip on the queue strip, is named properly in the action-bar check,
  and is recognised when you cast it** — so the strip pops it and anything that ability is set to do
  "when you use it" actually happens. Four lookups still stopped as soon as they found no class
  data. An ability added part-way through a session is picked up straight away, without a `/reload`.
- **Fixed: the "no visible action-bar button holds X" warning no longer repeats.** It is said once
  per ability, and not again until a button for that ability turns up and is taken away again. It
  used to be forgotten every time the client reported any change to the action bars — which on a
  paladin is every aura swap — so the same warning could fill the log several times a fight while
  nothing about the bars had changed. It also names the ability the way the game does ("Divine
  Storm") instead of by Elmira's internal key.
- **Fixed: the Notifications Log can be copied.** Its lines are in a read-only box you can select
  and copy out of, newest first, instead of text no widget could reach.
- **Fixed: every Move mode gets the options window out of the way.** Position the Strip, Position
  the Indicators, Move This Texture and Move screen messages hide the window and leave a small bar
  on screen naming what is being moved, with a Done button; Done or Escape brings the window back
  exactly where it was, on the same page and tab.
- **Fixed: the options window stays where you drag it.** Its position and size are saved the moment
  you let go, so pressing Preview, Test or any other button no longer snaps it back to where it was
  last saved — or to the centre of the screen.
- **Changed: the options window is no longer clamped to the screen** and can hang off an edge like
  any other frame. A saved position that would leave its title bar entirely off-screen — after a
  resolution or scale change — is still discarded, and the window opens centred.
- **New: the Texture tab works.** Any ability can put a texture on screen: its own spell icon, one
  of eight shapes that ship with Elmira (ring, disc, square, diamond, arrow, star, bar, chevron) or
  any texture file you name. Pick its size, colour and opacity, and which of five moments it appears
  at — it stays on screen while Elmira is suggesting the ability or while its buff is up, and
  flashes for a second and a half when the ability comes off cooldown, when you use it, or when its
  buff is about to run out. Off for every ability until you switch it on, with a Preview button and
  a line on the tab if you leave it on with no moment ticked.
- **New: an Indicators row above the queue strip.** Textures set to "with the other indicators" flow
  into a row centred on it, so several never sit on top of each other. "Position the Indicators" on
  All abilities › Texture puts a sample on screen and lets you drag the row anywhere; until you do,
  it floats above the queue strip and follows it. A single texture can instead be pinned to the
  centre of the screen, or dragged to a spot of its own with "Move This Texture". Both move modes
  work in combat, and closing the options window ends them.
- **New: `/elm debug textures`** — per ability, what it draws, how big, where it sits, which moments
  it appears at and when it last appeared, plus whether the file it names resolves at all.
  `/elm debug textures <ABILITY_KEY>` shows that one for a second and a half.
- **Changed: Remove sits at the top of an ability's General tab**, on the identity line and
  right-aligned, instead of below the last slider.
- **Fixed: on a class Elmira ships no data for, an ability you registered yourself now shows its
  own icon and its own name** — on the queue strip, in the Abilities list, in announcements and as
  the "this ability's icon" texture. The lookup used to stop as soon as it found no class data.
- **New: the Screen-edge tab works.** Any ability can flash a screen edge — left, right, top or
  bottom — in a colour and at a brightness you choose, when Elmira suggests it and/or when it comes
  off cooldown. Off for every ability until you switch it on, with a Preview button that fires the
  real flash, and a line on the tab if you leave it on with neither moment ticked.
- **New: your class pack can ship a screen flash already switched on for the one or two abilities
  worth glancing away for.** The paladin data ships two: Exorcism (red, left edge) and Divine Storm
  (blue, right edge). Everything else stays off, and anything you set yourself wins over what the
  pack says. Their one-line reason now shows under "What the class pack says" on the ability's
  General tab.
- **New: Abilities › Share.** Export every ability setting on this character as a string, or export
  a rotation together with the settings of the abilities it uses, and paste either into the box to
  merge them in — after a confirmation naming how many abilities it will overwrite. Settings for a
  spell this character does not know are kept and shown greyed in the list as "not on this
  character", and become a normal ability the moment your client can resolve it.
- **New: the Rotations Share tab can export.** A button puts the rotation you are looking at into
  the box, with an "Include ability settings" tick box beside it; importing such a string applies
  both and says how many abilities' settings came with it.
- **Changed: an ability's icon is greyed unless one of Texture, Screen-edge, Sound or Announcement
  is on for it.** The glow no longer counts: it is on for everything by default, so it left every
  icon in the list looking configured. The row's tooltip and the "Show › Any configured" filter
  follow the same rule.
- **Changed: `/elm debug cues` reports per ability** — which edge, which moments, when it last
  fired — and `/elm debug cues <ABILITY_KEY>` test-fires that one ability's flash.
- **Changed: the old build-level cue lists are gone**, along with the Peripheral cues controls on
  the Notifications page, which now points at the ability's own Screen-edge tab.

- **New: every ability has its own settings, on a rebuilt Abilities page.** The page is two tabs
  now, "Abilities" and "Share", and the abilities themselves sit in a list of their own with the
  add box and a search row above it. Pick one and you get six tabs: General, Glow, Texture,
  Screen-edge, Sound and Announcement. Texture is a placeholder in this update.
- **New: "All abilities" is the first row of that list.** It holds what every ability falls back
  to. Each ability opens with "Same as All abilities" switched on; turn it off to give that one
  ability its own glow style, colour and sliders, its own sounds or its own wording. Whether a
  screen flash, a sound or an announcement is switched ON is always the ability's own choice — it
  can never be turned on for everything at once.
- **New: sounds per ability.** Choose a sound for any of five moments: when Elmira suggests it, when
  it comes off cooldown, when you use it, when its buff appears and when that buff is about to run
  out. "None" everywhere by default, and the sound plays as you pick it. One master switch,
  "Ability sounds", is on the Notifications page.
- **New: "Announce when I use this" per ability**, optionally with how long the effect lasts
  ("Divine Protection used — 10s."). Off for every ability, long cooldowns included. The old rule
  that only announced cooldowns above two minutes is gone — length could not tell a defensive save
  from a burst cooldown, and now you decide per ability.
- **Changed: "Long cooldowns used" is back on the Notifications page**, with its Party and Raid
  checkboxes, because where the line goes is still a routing choice. There is no length slider.
- **Changed: the glow style, colour and sliders moved off the Glow page** onto Abilities ›
  All abilities › Glow, where any single ability can now differ. Whether your bars glow at all is
  still General › Action Bars, and the Glow page says where its controls went.
- **Changed: ability settings are per character.** Glow, sounds and announcements do not switch with
  your profile any more.
- **New: an ability's row in the list shows its own spell icon**, greyed when nothing is switched on
  for it, with a tooltip listing which of its five cues are on. The search row filters by name or by
  which cue is configured.
- **Fixed: "Add an ability" is one row instead of three panels** — your spellbook on the left, one
  box for a spell ID or a name on the right. Digits are looked up as an ID, anything else as a name.
- **Fixed: Elmira no longer announces its own uncertainty as a change to your character.** When the
  client would not say whether a spell is learned, a gated line counted as available again, so a
  reading that wobbled read as the ability being gained and lost — several messages a fight about a
  rune that had not moved. A verdict Elmira could not actually read is now neither announced nor
  remembered: whatever was last known stands until the client answers again. Real changes — a rune
  engraved, a set piece equipped, a spell trained — are announced exactly as before.
- **New: `/elm debug gates` now lists what the client answers for every gated spell** — `true`,
  `false` or `cannot tell` — so a message about a line coming or going can be checked against the
  reading behind it.
- **Changed: two kinds of notification are named for what they carry.** "Rotation changes" is now
  "What just changed" — it fires mid-fight when a line of your rotation becomes usable or stops
  being usable, which the old name made sound like settings chatter — and "Status" is now "Settings
  and setup". The new names appear on the Notifications page and in front of every line in the log.
- **New: picking a sound on the Notifications page plays it.** The list is whatever your media packs
  provide, so choosing by name alone was guesswork; you now hear the sound as you select it.
  "None" stays silent.
- **Changed: "Long cooldowns used" is no longer on the Notifications page.** Whether a long cooldown
  is worth announcing depends on the ability — a defensive save and a burst cooldown are not the same
  message — so it is becoming a per-ability setting instead of one routing row. The Party and Raid
  checkboxes and the cooldown-length slider go with it, and "Test Each Kind" no longer sends a sample
  of it.
- **Changed: the Notifications log is a "Notifications Log" panel at the bottom of the page.** It
  used to sit at the top, one row per message, so every switch below it moved further down as Elmira
  talked. The settings stay where you left them now, whatever is in the log, and the log still reads
  newest first with its own Clear Messages button.
- **Changed: "Move screen messages" always works.** It was greyed out whenever positions were
  locked — which they are by default — and told you to go and unlock them on another page. It is now
  a button that works like "Position the Strip": press it to show a sample of every kind of message
  and drag it where you want, press "Done Moving" when you are finished. Your lock setting is never
  changed, and locking positions (or `/elm lock`) ends it, as does closing the settings window.
- **Changed: the Queue page is three panels instead of one long list** — "When you see it", "Size and
  position" and "What it tells you". The two settings whose names read the same are gone with it:
  the switch at the top is "Enable the queue strip" and the dropdown is "When to show it". "Icons" is
  now "Casts to show", "Strip scale" is "Size" and "Grow" is "Direction". Every control's tooltip has
  been rewritten to say what it does and when you would want it, and Learning mode's now names all
  three settings it changes for you.
- **Fixed: with the queue strip switched off, the twelve settings under it still looked live.** They
  are greyed out now and say which switch turns them back on, while still showing the values you
  saved. "Out-of-combat opacity" is greyed out the same way when the strip is set to combat only.
- **New: "Position the Strip" on the Queue page.** Puts the strip on screen with sample icons and
  lets you drag it, even in the moments it is normally hidden, so you no longer need a target dummy
  to place it. Press it again when you are done — closing the settings window ends it too — and your
  lock setting is left exactly as it was.
- **New: the queue strip can grow left, down or up as well as right.** Pick a direction with "Grow"
  on the Queue page. The first icon does not move when you change it, so you can position the strip
  where you want it and then decide which way the rest of the queue lays out; the slide and drop
  animations follow the new direction.
- **New: the strip can fade while you are out of combat.** "Out-of-combat opacity" on the Queue page
  dims the whole strip and goes back to full the moment a fight starts. It is for keeping the strip
  visible but quiet; hiding it entirely out of combat is still "Show the queue".
- **New: the space between the icons is a setting.** "Spacing" on the Queue page, 0 to 20 pixels;
  zero makes the strip read as one solid block.
- **New: "Match my action bars" beside the strip scale.** Measures a button on your action bars and
  sets the strip's scale so the first icon is drawn the same size. It needs one of the rotation's
  spells to be on a bar you can see, and says so rather than guessing if it cannot find one.
- **New: the queue strip says how long until each later suggestion happens.** A small countdown in
  the icon's bottom-left corner, ticking down live. It stays quiet when the wait is just the next
  global cooldown — which is most of the time — so the number only appears when there is a real gap
  worth knowing about. "Show waits" on the Queue page can silence it or show it on every icon.
- **New: the first icon dims when you cannot afford the suggestion.** Only for a resource you are
  short of; being out of range deliberately changes nothing, so an icon does not flicker while you
  run at a target.
- **Changed: the keybind on the queue icons is readable now.** It is outlined, near-white instead of
  grey, and sized to the icon it sits on, so the big first icon carries the bigger key. A new
  "Keybinds" setting puts it on the first icon (as before), on every icon, or on none.
- **New: "Show the rule name" is its own setting on the Queue page.** The name of the rule that
  chose the suggestion used to come only with Learning mode, which meant giving up the queue to see
  it. Learning mode still works exactly as it did, and now switches this on for you.
- **Fixed: clicking a bank NPC, a vendor or a flight master made the queue appear.** "In combat, or
  when you have a target" now means a target you can actually fight.
- **Changed: Action bars is no longer a section of its own** — everything it held now sits on the
  General page, under a heading called Action Bars, between the panel scale and the slash-command
  list. It is renamed Bar Addons and Action bar glow inside, with "Also glow your action bar" now
  reading "Enable action bar glow" and moved next to Preview Glow, above the checks that explain it.
- **Fixed: "Enable action bar glow" could be switched on and still glow nothing.** There were two
  switches for one effect; the second one, "Glow the next cast" on the Glow page, is gone and
  "Enable action bar glow" is now the only thing that decides whether your bars light up.
- **Changed: the cast-after-next glow moved to General, under Action Bars.** Its toggle is called
  "Glow the next cast" now, with "How dim it is" and Preview beside it, and all three are greyed out
  while the action bar glow is off. The Glow page keeps the glow's style and colour.
- **Removed: the second glow no longer has a style of its own.** It always draws in the same style
  as the main glow, just dimmer, so it cannot override the per-ability look you are about to be able
  to set. Brightness stays adjustable.
- **Changed: the bar addon list uses the same status pictures as the Builder**, so "in use",
  "another addon is handling your bars", "available" and "not installed" each look different
  instead of sharing one grey dash, and the status wording is coloured to match.
- **Changed: the General page's Enable Elmira, Choose Your Rotation, minimap and lock controls sit
  on one row**, with the last two against the right edge, and the panel scale is a plain slider
  rather than a boxed section of its own.
- **Changed: a rotation's buttons sit together against the right edge of its detail panel**, and the
  name beside them grows to fill whatever they leave — including on the rotation you are already
  using, which shows no Use button.
- **Changed: Edit moved to the top of your own rotation's panel**, next to Rename and Delete, so you
  no longer scroll past the whole rotation to reach it. It still switches to that rotation before
  opening the Builder, and still stops and tells you why if it cannot.
- **Changed: Use is green and Edit is purple** on the rotation pages and on the cards, matching the
  Builder's rule that a button's colour says what it does. Rename and Copy Source Link stay plain.
- **New: a Reset button in the Builder puts the original template's lines back.** It works on your
  unsaved draft, so nothing is written until you press Save and Discard undoes it — which is why it
  asks no confirmation. It is greyed out for a rotation you started from scratch (there is no
  original to go back to) and for one that already matches its template.
- **Changed: Save, Discard and Reset sit together against the right edge of the Builder**, and
  buttons are now coloured by what they do: green for Save, red for Discard, Reset and Delete,
  purple for the ones that take you to another page. A greyed-out button stays grey. The Remove
  button on each rotation line deliberately stays plain.
- **Changed: "Right now" reads as two blocks**, the queue and its context above a blank line and
  the key to the symbols below it. "Status is as of the last time the queue changed." is gone.
- **Changed: the Abilities section has no Search box** until the list is longer than 30 abilities,
  which no shipped class pack is — it comes back by itself for a bigger list or once you have added
  a lot of spells of your own.
- **Fixed: the arrow between the spells in "Right now" drew as an empty box.** It is a small
  chevron image now, the same way the Builder's status marks are.
- **Fixed: the condition editor's Value dropdown listed internal keys** — "HOLY_POWER_CONSUME_HOLY",
  "JUDICATOR_SOUL", "CRUSADER_STRIKE_150". Each entry now reads as what the bonus actually does
  ("Divine Storm/Holy Shock/Holy Wrath consume Holy Power"), tier sets and shoulder souls read by
  name, and hovering the dropdown says where the selected bonus comes from — which set and how many
  pieces, or which Soul of the ... shoulder enchant, naming both when either will do.
- **Fixed: a condition said "the item in slot 13 is ready".** It now says "Trinket 1 is off
  cooldown", and every other equipment slot is named rather than numbered.
- **Fixed: the Value dropdown's label drew on top of the dropdown above it.** It has a row to
  itself now, which also gives the longer set-bonus wording room.
- **Fixed: the Search box and the first ability button shared a row** in the Abilities section, with
  the button sitting lower than the box. Search takes the whole row, so the grid starts below it.
- **Fixed: the tooltip on the left-hand menu covered the page.** It only ever repeated the menu
  entry's own name, and the change meant to remove it never took effect.
- **New: the Builder's status marks are six different shapes, not three grey dots.** "Cannot fire
  for your character", "switched off" and "changed but not saved" used to look identical. Each state
  now has its own symbol and colour, and hovering a line's +/- button says which one it is in words.
- **Changed: a rotation line is far shorter.** The reorder buttons are readable rather than
  truncated to "...", Top and Bottom join Up and Down, the repeated "Ability" label above every
  dropdown is gone, and the sentence under a line is now just its condition ("mana at least 40%")
  with nothing at all shown for a line that has no conditions. An item line no longer claims to be
  "cast". Opening a line draws its conditions in a titled box below the line instead of alongside it.
- **Changed: the Abilities and Items lists are a three-across grid.** The greyed-out reason
  ("engrave Aura Mastery", "empty") moved into the tooltip, the Search box moved inside the
  Abilities section so it is clearly a filter on that list, and "Add from Spellbook…" sits on its
  own highlighted row because it opens a page instead of adding a line.
- **Changed: "Right now" no longer numbers the live queue.** It reads
  "Seal of Righteousness > Holy Shock > Exorcism" with a small chevron between the spells, so it
  cannot be mistaken for the numbered rotation list below it. Save and Discard moved to the top of the Builder next to the "Editing …"
  status, and the unsaved Preview only appears when there really are unsaved changes.
- **Changed: the top of the Rotations page is now one line.** It reads what you are — "Level 60
  Paladin · 1H · SoD P8" — with the New Rotation button beside it, and anything Elmira cannot read
  about your character is left out rather than printed as a question mark. The playstyle cards
  below lost the phase and the Copy link button (the phase is on that line now, and the detail
  section has a Copy Source Link button), and "recommended"/"Unproven" moved onto the difficulty
  line so a card no longer carries a blank row.
- **Changed: clicking a playstyle card scrolls the detail section into view** if it was below the
  bottom of the window — the least amount needed to bring its header on screen, and not at all when
  it is already visible. The section is titled "Details" rather than repeating the rotation's name
  directly above the copy of it inside.
- **New: "What this rotation needs" shows each ability's icon** before its name. Set and gear
  requirements, which have no icon, are unchanged.
- **Fixed: requirement rows showed raw internal keys** — "HOLY_SHOCK known", "T3_5_HOLY: 2/4
  pieces". They now read "Holy Shock known" and "Radiant Judgement: 2/4 pieces", using the client's
  own spelling of an ability's name wherever it can be read.
- **Changed: button labels are Title Case throughout the settings window** ("Copy and Edit", "New
  Rotation", "Reset These to Defaults"), matching the rest of the interface. Headings and
  explanatory text are unchanged.
- **Changed: clicking a playstyle card on the Rotations page now opens its detail in a section below
  the cards, instead of a separate page in the menu.** Your own rotations now also appear as their
  own row of cards on the same page, next to the shipped playstyles, so you can jump straight to one
  without going through a template first.
- **Fixed: a rotation line could be wrongly marked red ("a logic error to fix") for a seal condition
  written as "not" or as one option of several ("any").** Both are working conditions — a negated
  seal check is often meant to always be true when nothing casts that seal, and an "any" branch can
  still fire through its other option — so the page no longer treats either as broken.
- **Fixed: the first-time setup popup could open behind the settings window** if the window was
  already open when it appeared, the same way the rotation-naming popups once did.
- **Fixed: the Abilities page's "From your spellbook" list was sorted by an internal id, not by
  name**, which looked like a random order in game. It's now sorted alphabetically.
- **New: the Abilities page's "From your spellbook" list now shows each ability's icon** next to
  its name; anything without one still shows a plain name.
- **Fixed: a rotation you copied on one character could show up on another of a different class.**
  Forks are stored account-wide, and the class check that keeps them apart used to fall back on
  your class's own data pack — but only Paladin ships one, so every other class saw everyone else's
  rotations too. It now always checks your actual class. A rotation now also has its own "Only this
  character can see this rotation" toggle (off by default) for keeping one to yourself; every other
  character of your class sees your rotations as before. "New rotation" also works now for a class
  with no shipped pack yet, which the same fix had otherwise left creating something you could never
  actually switch to.
- **Changed: the Spells page is now called Abilities**, and the settings menu is reordered to
  General, Rotations, Abilities, Queue, Action bars, Glow, Notifications. Nothing about how a spell
  or rotation is stored changed — only the names you read.
- **Fixed: editing a rotation printed "build '...' failed validation" to chat two or three times per
  action.** A half-built rotation normally fails to compile while you are still working on it; the
  live preview now checks that quietly and only shows the reason in the preview box itself. The same
  message still prints once, as before, if a rotation actually fails to load at the start of a
  session — that one is a real problem, not a normal part of editing.
- **Fixed: several Status/Problems and chat messages still repeated "Elmira" twice**, following up
  the earlier fix for the same thing.
- **Fixed: the Abilities page's "by ID" and "by name" boxes kept your last attempt in them.** After
  adding a spell, or after a name it could not find, the box now clears either way; a refused
  attempt still shows why underneath it.
- **New: the Builder is now a column of panels, one per line.** Collapsed, a line reads as a full
  sentence — "Exorcism is cast when mana is at least 40%" — with its ability shown in an in-place
  dropdown you can change without removing and re-adding the line, a status dot, and the reorder/
  remove controls. Click the panel open to edit its conditions as sentence rows (subject, kind, key,
  a "not" toggle), add another, or remove one; a condition's key list now also offers anything you've
  registered on the Abilities page, with a link straight to that spell's own page.
- **New: a third status colour for a rotation line's conditions.** Grey and amber keep their meaning
  (cannot happen on this character right now; waiting on something that can still become true); red
  is new — a condition that can never come true as the rotation stands, such as one checking a seal
  no line of the rotation casts any more. The Rotation page now counts how many lines need attention.
- **New: a live preview of your unsaved changes**, shown above the running rotation's own "Right now"
  strip while the Builder is open, so you can see what a draft would suggest before pressing Save.
  The rotation actually running on screen never changes until Save is pressed.
- **Fixed: the Rotations page's playstyle cards read as one wall of text.** Playstyles now show as
  cards, three across: a short title, a short description with the full text on hover, difficulty
  shown as pips, a muted line of extra detail, and two stacked buttons — Use, and Copy link (which
  opens the full web address in a copyable popup, in front of the settings window). Clicking anywhere
  on a card's body opens that playstyle's own page. The card in use has a gold border; one you cannot
  use yet (missing gear or a rune) is dimmed instead.
- **New: spell icons appear before each line in a rotation's "top to bottom" list**, matching the
  Builder's own rotation list and the queue mirror.
- **Changed: the status dots' colours are swapped.** Grey now means a line cannot happen on this
  character right now (missing gear or a rune, or switched off); amber means it can fire, it is just
  waiting on a condition (cooldown, target health, and so on).
- **New: an Abilities page**, right after Rotations, listing every spell, buff or debuff your rotations
  use — added automatically as you use them — with three ways to add anything else: from your
  spellbook, by spell ID (previewing what it resolves to before you commit), or by name (only for a
  spell this character has learned or seen; anything else is refused, in red, and never stored). Each
  spell gets its own page saying where it came from and which of your rotations use it; on-screen
  cues for individual spells are coming in a later update. The Builder's own "Add a spell" list now
  reads this registry, with an "Add from spellbook…" row at the end that jumps straight to it.
- **New: combo points are a power you can write a condition against**, alongside Mana, Rage and
  Energy — for classes with no shipped rotation pack yet, this is what makes a finisher condition
  ("5 combo points") expressible at all.
- **Fixed: New rotation, Copy and edit and Rename were all unusable.** Their popup always rendered
  behind the settings window, its name box was always empty however it was opened, and the button
  (and Enter) silently did nothing when the box came back empty. The popup now shows properly in
  front of the window while it is open, and puts itself back exactly the way it found things
  afterwards — including never touching another addon's own popups, since the popup frame is shared
  with the rest of the game. The suggested name survives being shown, Enter accepts the box exactly
  like clicking the button does, and a name that still cannot be used now says why instead of doing
  nothing.
- **Fixed: New rotation and Copy and edit still refused a typed name as empty.** The name box and
  the accept button are shared, client-owned widgets this addon does not hold a direct reference to
  on every version of the client; the popups now find them the same way the game itself does, so
  Enter and the button both read what was actually typed.
- **Fixed: a couple of Status/Problems messages repeated "Elmira" twice** ("Elmira: Elmira: …").
- **Fixed: the Builder's Save button could look enabled for a line it was about to refuse anyway.**
  If a line names a spell this character cannot resolve — a rotation you built on one character that
  names a spell only that character registered, opened on another — Save now greys out and names the
  line, before you click it, instead of after.
- **Fixed: a spell you registered yourself (by ID, by name, or from your spellbook) now actually
  works in a rotation.** Saving a line naming one used to be refused outright even after the Abilities
  page had accepted it; it now saves, and the rotation reads its cooldown, usability and whether you
  know it exactly the way it does for one of your class's own spells. If your class ever ships that
  same spell under its own name, the shipped one always wins. A rotation exported from one character
  and imported on another that never registered the spell is refused with a plain reason rather than
  silently dropping the line.
- **Fixed: `/elm config` opened on the Rotations page instead of General.**
- **New: the Rotation page is now a tree, and it is the whole front door.** Rotations replaces the
  old Rotations/Builder/Share tabs: every catalog playstyle for your class is its own page (what it
  needs, its rotation top to bottom, a Copy and edit button), your own copies nest under the
  template they came from, and Builder and Share sit at the end of the same list. A root page lists
  every playstyle with a summary and a Use button, and offers New rotation for building one from
  scratch. Playstyles Elmira has no rotation for yet (seal twisting, seal stacking) are listed too,
  greyed, on a page that says so — rather than being missing with no explanation.
- **New: Use switches your rotation and says so on screen**, by name — never the internal key a
  fork is stored under. The rotation already running shows "in use" instead of a button. If it
  cannot switch (no character loaded, an unknown rotation), the button says why instead of doing
  nothing, and Edit on a fork no longer opens the Builder on the wrong rotation when that happens.
- **New: name your own rotations.** New rotation and Copy and edit open a small popup with a
  suggested name (colliding names count up); Rename and Delete live on a rotation's own page.
  Deleting the one you are running leaves none in use rather than a display quietly stuck on a
  build that no longer exists.
- **Removed: the setup wizard window.** Choosing a playstyle is the Rotations tree now. In its
  place, a first-run popup offers to open it the first time a character has no rotation chosen, and
  a status line reminds you the same way if you dismiss it. `/elm setup` still works, as an alias of
  `/elm rotation`. "Run setup again" is gone from the General page.
- **New: the queue strip shows a one-line reminder when nothing is chosen yet**, with a click that
  opens the Rotations tree. Off by its own toggle if you would rather not see it; never shown in
  combat.
- **Fixed: a rotation-change announcement could show the internal `USER_...` storage key** instead
  of the name you gave your own rotation.
- **Changed: Notifications is one page.** What used to be an "Announcements" tab is now the whole
  page: the Log sits at the bottom, and each kind of message — Rotation changes, Problems, Status,
  Long cooldowns used — is one row with Chat/Screen/Sound switches and, for Long cooldowns used,
  Party and Raid switches too (previously one switch covered both, and always guessed which). Every
  switch's tooltip says when that kind of message actually happens. Peripheral cues and Cue sounds
  stay exactly where they were, reachable from the same page.
- **New: a sound per kind of message**, not one shared sound for everything — turn Sound on for a
  row to pick which one plays for it. Left alone, it plays whatever the row below used to.
- **Changed: chat lines go to every chat window that shows System messages**, not a tab picked once
  and forgotten. The old "Chat window" dropdown is gone.
- **Changed: several plain chat prints are now Status or Problems announcements** — a rotation that
  failed to apply, a missing data pack, the rotation queue being disabled, ItemRack not being found,
  and the settings window failing to remember its size — so they show up in the Log and follow your
  routing instead of always landing in your main chat window.
- **Changed: the message Log now keeps the newest 20 lines** (was 200) to match what the page
  actually shows, and the "N lines dropped" counter is gone with it.
- **New: the settings window opens big enough to read, and remembers itself.** 960x680 rather than
  700x500, drawn 20% larger, and the size and place you leave it in come back after a reload. A
  **Panel scale** slider on the new General page changes it as you drag.
- **Changed: the settings window has a proper title bar.** The whole strip drags now instead of a
  tab in the middle of it, the name stays centred on it, and there is an X in the top right next to
  a button that puts the window back to its default size and position if it ends up off screen. The
  version now sits to the left of the bar on its own line, so dragging the panel scale slider no
  longer makes it disappear until you close and reopen the window. The settings window also no
  longer leaves its buttons behind on other addons' Ace3 windows.
- **Changed: the first page is now General** — Enable Elmira, Run setup again and the panel's own
  scale. **Queue** keeps everything about the strip, and its Scale slider is called **Strip scale**
  so the two are told apart.
- **New: General gained a "Choose your rotation" button, a minimap-button toggle and "Lock all
  positions".** The button jumps straight to the Rotation page of the panel you already have open.
  Show minimap button shows or hides Elmira's launcher icon and remembers it across a reload. Lock
  all positions replaces Queue's old "Lock position" toggle — it now locks the on-screen message too,
  and locking it also lets go of the message if you were mid-drag.
- **Fixed: "Choose your rotation" made the left menu (General, Queue, Rotation, ...) disappear.**
  So did `/elm rotation`. Both now land on the Rotation page with the rest of the panel intact.
- **New: General ends with a read-only Slash commands list**, every `/elm <command>` and what it
  does, so it can never say something `/elm` itself does not actually do.
- **Changed: the explanatory text throughout the settings is no longer smaller than the labels above
  it.** It was two points down everywhere, worst on the Builder, which is almost all text.
- **New: the Builder checks your rotation for you.** Underneath the list, in a **Checks** box that
  only appears when there is something to say: a line an earlier line always beats, and a line that
  names a spell or set your class data no longer has. Both are certain rather than sampled — they
  are read off the rotation itself, so neither can be wrong about a situation nobody thought to try
  — and neither stops you saving. They appear while you edit, not after you save.
- **New: when a template you forked has been updated, the panel now says what is different.** Under
  the "has been updated since you forked it" line: which lines the template has that yours does not
  and the other way round, which lines have different conditions, and which have moved. Your
  rotation is never rebased over — the point is that you can read the difference and decide.
- **Fixed: moving a line in the Builder, or switching one off, did not change the rotation you were
  actually running until you reloaded.** The panel showed the new order, the queue kept firing the
  old one, and nothing said anything was wrong. The compiled copy of a rotation was cached against
  the rotation itself, and editing a line changes the rotation in place — so the cache never noticed.
  Every edit now drops it.
- **New: the Builder edits conditions.** Pick a line and its conditions appear underneath as rows you
  choose from lists — category, field, test, value — with a `not` switch and a choice of whether the
  line needs every condition or any one of them. Lines whose conditions nest more deeply than that
  are shown in plain words and left alone rather than rewritten.
- **New: the Builder edits a draft, and you press Save.** Reordering, switching a line off, adding
  one from the palette and every condition change go to a draft; Save writes it and repaints the
  display, Discard puts it back. Anything the rotation compiler cannot read is listed underneath the
  Save button, which stays greyed out until it is fixed.
- **New: every line says what it is doing right now.** A coloured indicator dot per line — green
  firing now and in which slot, amber not active for you (with the gear or rune it needs), grey
  waiting (with the condition it is waiting for), switched off, or not saved yet — and the queue
  itself mirrored above the list with your target, its health, the enemies around you and your
  mana. It refreshes when the queue changes, and never while you are typing into a box.
- **New: click a spell or an equipment slot in the palette to add it** to the bottom of the rotation
  you are editing. `Remove` on a line takes it back out.
- **Changed: a line now says what it waits for instead of counting.** "2 conditions" said the same
  thing about every line that had two; it now reads "no seal is up, mana at least 30%".
- **Fixed: Elmira's memory figure climbed by megabytes a minute while you stood still, when every
  other addon's stood flat.** The display recomputes the queue four times a second whether or not
  anything changed, and every recompute allocated about 30 KB it then threw away: the queue rebuilt
  its whole simulation scratch state (thirty closures, six tables) each time; the per-frame cache
  below threw its tables away every frame and made new ones -- it had made the growth worse, not
  better; the aura scan built a record per buff per frame; and the queue tables, the pack lookup and
  the visibility check each added a little. Nothing is rebuilt now: the simulation state is made
  once and reset, the caches are stamped on permanent tables, aura records persist, the queue is
  double-buffered. Measured on the shipped Shockadin build with a moving clock: **21.5 KB per
  recompute before, 0.01 KB after**, nothing retained across 3000 recomputes. The answers only a
  rune, rank, level or gear change can move -- a spell's mana cost, which runes are engraved, the
  soul on your shoulders, your weapon -- are read once and again on those events, and on entering
  the world. A new spec ticks the whole stack with a moving clock and fails if a steady rotation
  allocates again.
- **New: `/elm debug alloc` says which question one refresh pays for.** `/elm debug memory` can say the
  simulation allocated so much per refresh and nothing more; this measures a single refresh on a
  fresh frame and charges it to each thing the rotation asked -- cooldowns, buffs, the seal, runes,
  set bonuses -- plus whatever none of them accounts for, and says whether the spellbook cache is
  holding and how often a character change has emptied it.
- **Fixed: a talent respec that learned no new spell left a held mana cost stale** (Benediction moves
  a seal's cost). Talent changes now clear the held answers like a rune or a level does.
- **Fixed: the rotation asked the game 764 questions to work out one suggestion.** It now asks about
  60. The queue looks five casts ahead across every line of your rotation, and nothing remembered an
  answer between one question and the next — so the same handful of facts (is this on cooldown, do
  you know it, what are you wearing) were fetched from the client hundreds of times for a single
  refresh, four times a second. None of them can change without a frame passing, so none of them
  needed asking twice. Measured in game before the fix: **111 KB of memory a second, 80–91% of it
  here.**
- **Fixed: working out the global cooldown scanned your whole spellbook, ten times per refresh.**
  Two separate functions each walked every spell in the rotation looking for one showing a global
  cooldown — and out of combat nothing is, so both ran to the end every time, once per look-ahead
  step. They now share one pass and remember the answer for the frame. On its own that was 264 of
  the 764 calls, before your rotation's own conditions had asked anything.
- **Fixed: counting your set pieces re-read all nineteen equipment slots once per set**, and rebuilt
  the set's item list every time it did. Six sets meant 114 reads to answer nineteen questions.
- **`/elm debug memory` now says which PART of the display loop the memory went to.** Knowing the
  loop owns the growth is not the same as knowing what to rewrite, so the measurement now breaks the
  running window down by phase — reading the visibility, resolving the build, simulating the queue,
  and each renderer by name — with a rate, a call count and a per-call cost for each. The accounting
  is off unless a measurement is running, so an ordinary frame pays one comparison for it.
- **New: `/elm debug memory` — is the memory growth actually Elmira's?** The client reports one
  number per addon and it only ever goes up; it cannot tell a leak from churn, and it cannot tell
  our allocations from those of the shared libraries we happen to own. This measures the one thing
  that separates them: it samples Elmira's memory for twenty seconds with the display running, then
  for twenty with the display suspended, and compares the two rates. If they match, nothing in the
  render loop is responsible.
- **New: `/elm debug libs` — which shared libraries the whole UI is getting from us.** LibStub hands
  out exactly one copy of each library, and the client bills a function's memory to the addon whose
  file defined it. Elmira embeds eighteen libraries, so whenever our copy is the one that won, every
  *other* addon's use of it is charged to Elmira's memory figure — ElvUI's event dispatch, WeakAuras'
  glow animations, everyone's timers. This lists exactly which ones those are, and `/elm debug perf`
  now says so beside the number instead of leaving it to be read as a leak.
- **Fixed: Elmira was by far the most memory-hungry addon on the list, and did not need to be.**
  Every time the rotation asked whether you had a buff, it walked all forty aura slots and asked the
  game about each one **twice** — the second time only to learn which spell it was, which the first
  answer already contained. A rotation with a dozen aura-gated lines, looked ahead five casts, did
  that hundreds of times a second. It now reads your auras **once per frame** and shares the answer.
  Measured on the shipped Exodin rotation: 275 game calls per refresh before, 13 after.
- **Fixed: "Cooldowns used" never said anything.** The category had its own colour, its own routing
  and the only party/raid switch in the addon — and nothing anywhere ever produced a message for it,
  so switching it on and using a cooldown was silent. Using a long cooldown is now announced, with
  the ability's icon: *"Avenging Wrath used."*
- **New: Only cooldowns longer than…** — a setting for what counts, since the panel could not say.
  It ships at two minutes, which for a paladin means Avenging Wrath and Aura Mastery and nothing
  else; below that it would be a line almost every fight, and Crusader Strike would announce itself
  every six seconds. This is the one kind of message that can reach party chat, so the bar is high
  on purpose.
- **Fixed: `/elm debug perf` said the bar map was empty when it was not.** It reported
  *"bar map: 0 spells, built=false"* while `/elm debug bars` showed a bar addon holding 43 mapped
  spells in the same install — a diagnostic saying the display was broken when it was working. Both
  numbers were right; the label was wrong. The line now names which map it means, says how many bar
  addon providers are in use, and explains that the Blizzard fallback being unbuilt is expected
  while a bar addon is handling your bars. It also no longer builds the map as a side effect of
  being asked, which is why the two commands could disagree about the same session.
- **The hint on the cast after next can now use its own glow style.** Telling it apart by
  brightness alone did not work: Proc drives its own brightness, so the hint came out looking
  identical to the real suggestion. It can now be a different SHAPE — pick any style for it, or
  leave it as "Same as above" — with a slider for how dim it is and a **Preview the hint** button
  that flashes the same button as the ordinary preview, so the two can be held side by side without
  waiting for a fight. All of it appears only once the hint is switched on.
- The hint's settings moved to the bottom of the Glow page under their own heading, after everything
  that describes the main glow, because they are a separate signal rather than another property of
  that one.
- **New: Reset these to defaults**, on the Glow page. The settings are worth playing with and there
  was no way back — the colour picker's own Default button belongs to the game's colour frame and
  never touched what Elmira had stored.
- **Fixed: the queue never popped the spell you cast.** Casting the current suggestion was supposed
  to make its icon pop and fade as it left, telling it apart from the rotation simply changing its
  mind. It slid like any other change instead: the cast was noted and then thrown away on the very
  next redraw, which happens a fraction of a second before the spell's cooldown registers and the
  queue actually moves. The cast is now kept until it is used, and forgotten after one global
  cooldown if the queue never moves.
- **Fixed: abilities you had learned were shown as "not learned yet".** Classic gives every rank of
  a spell its own id and Elmira's data records one of them, so asking the game about that exact id
  answered "no" for anyone holding a different rank — Exorcism and Holy Wrath both showed greyed for
  a paladin who had them. It now asks your spellbook by name as well, which has no ranks. This
  affected more than the display: rotation lines using those abilities were being reported as
  unavailable, so `/elm debug gates` listed lines that were in fact perfectly able to fire.
- **New: the Builder lists your rotation, and you can reorder it.** Every line in priority order
  with its icon and what it waits for, and on a rotation of your own each line has an on/off switch
  and arrows to move it. The order is the rotation: the first line that can fire is the one you are
  told to press. Templates show the same list, read-only.
- **New: Customize.** On the Rotations tab, Customize makes your own editable copy of a template
  **and switches to it in one click**, so you are never left editing a copy while still playing the
  original. The copy remembers which template it came from and which version of it.
- **New: a Rotation section, and `/elm rotation` to open it.** It is now the first thing in the
  settings window: what you are running, the templates that ship for your class, and your own
  rotations listed separately. If you are running one of your own, it says which template it came
  from and tells you when that template has been updated since you copied it. Import / Export moved
  here as the **Share** tab.
- **New: the Builder tab shows everything your rotation can use.** The abilities your class data
  covers, with their
  icons, searchable, and your trinkets — with every other equipment slot behind a toggle, since
  almost nothing else is ever on-use. Abilities you cannot cast yet are still listed, dimmed, with
  the reason beside them: a rune-granted one names the rune to engrave rather than just saying you
  have not learned it, because that is the thing you can go and do. Putting them in an order is the
  next step.
- **Fixed: closing the settings window could leave the Escape key dead.** Elmira replaced the
  settings window's own close handler instead of adding to it, so the window was never released
  when it closed. Anything you had clicked into — the import box, a slider's number — kept the
  keyboard, and every later Escape went to that invisible box instead of opening the game menu.
  The window is now released properly, and nothing Elmira does on close can stop that happening.
- On-screen messages no longer depend on message-frame calls existing: a client missing one now
  loses that touch and says so once, instead of erroring from inside the settings window closing.
- **New: Elmira tells you when your gear changes your rotation.** Equip the fourth piece of a set,
  engrave a rune, or hit the level a line was waiting for, and it says so once: *"Divine Storm
  consumes Holy Power: Divine Storm is now active in PALADIN_EXODIN."* — and the reverse when you
  take the piece off. On a client that cannot read engraving at all it says nothing about runes
  rather than claiming they are missing. It only reports things that stay changed: a line waiting on your mana or on
  three enemies is the rotation doing its job, not news. **`/elm debug gates`** lists every line of
  your rotation that cannot fire for this character right now, and what each one is waiting for.
- **Fixed: three events were registered twice, and the first handler of each was silently
  discarded.** Entering combat, leaving combat and changing gear all had two handlers registered
  for them, and the game keeps only one — so the combat-start and combat-end work never ran at all.
  That took the recorder's in-combat sampling and its gear-change marks with it. Found while
  writing a test for something else; there is now a check that fails if any event is ever
  registered twice again.
- **New: you decide how Elmira talks to you.** A new **Notifications → Announcements** page splits
  everything the addon says into six kinds — rotation changed, template updated, mode, warnings,
  status, cooldowns used — and lets you send each one where you want it: your chat window (any tab,
  not just the default one), an on-screen message in the middle of your screen, a sound, or
  nowhere. Whatever you choose, every message is kept in a **Log** at the top of that page and the
  last few show on the minimap tooltip, so silencing something never means losing it. On-screen
  messages wait for the fight to end rather than landing mid-pull, each kind has its own colour,
  and the font, size and position are yours — drag it with **Move**, which shows a sample of every
  kind so you can see how much room it needs and switches itself off when you close the panel or
  enter combat. **Test each kind** sends one of each, and never to your group.
- Party and raid chat is offered for exactly one kind of message, cooldowns used, and ships off.
  Nothing about your own rotation can be routed to a group — that is fixed in the addon, not a
  setting, because "Divine Storm is now active in my rotation" is noise to everyone but you.
- Peripheral cues and cue sounds moved under the same **Notifications** heading. They were sitting
  beside "Queue" and "Action bars", which mixed up what the addon draws with how it talks to you.
- **The action-bar glow is yours to style now.** A fourth style, **Proc** — the modern burst-then-
  pulse animation — joins Pixel, Autocast and Button, and every one of them takes a colour, with
  sliders for however many particles travel around the button, how fast they go, how heavy the
  outline is and how long a Proc pulse lasts. Rows a style has no use for are hidden rather than
  left there doing nothing. **Preview glow** now sits on the Glow page as well, and re-fires as you
  change settings, so you can tune the look standing still instead of guessing mid-fight. Untouched
  settings keep the library's own defaults, so nothing changes until you change it.
- **New, off by default: a dim hint on the cast after next.** A second, fainter glow on the
  following suggestion's button. It ships off, for the same reason the queue strip stopped
  glowing — two lit buttons compete for one glance.
- **The queue strip no longer glows, and it moves instead.** The suggested spell used to light up
  twice at once — on the strip and on your action bar — for the same cast. The strip's half was the
  one you cannot press, so it is gone: the current suggestion is simply the biggest icon, the ones
  after it step down in size and opacity, and the strip tells you something changed by *moving*.
  Icons slide across when the queue advances, drop in from above when a spell is promoted (an
  execute coming into range), and the one you just cast pops as it leaves — so a glance at the edge
  of your vision reads as movement rather than as another thing lighting up. Turn the motion off
  with **Animate changes** if you prefer it still.
- **New: you can hide the strip and keep the action-bar glow.** The two used to be one switch, so
  losing the icons lost the glow with them. **Show the queue strip** now turns off only the icons.
  The master switch is relabelled **Enable Elmira** to stop it reading as the same setting.
- The keybind is shown on the current suggestion only. On a projected slot it was a key *not* to
  press yet.
- **Fixed: no bar addon was ever detected.** Elmira asked the library registry which action-bar
  libraries were loaded and misread the answer, so it always concluded there were none — ElvUI and
  Bartender4 users got the Blizzard-bar fallback, which ElvUI hides, so nothing glowed on the bars
  at all. Reported the same day the bar support shipped; it never worked in a live client.
- The Action Bars panel's status markers are plain text now. The symbols it used are not in the
  game's font and drew as identical empty boxes, so every row looked the same.
- "Test with" now lists only the spells your playstyle actually uses, each once. It was offering
  passive runes, which can never be on an action bar, and repeating abilities that share a name.
- **New: an Action Bars settings page that tells you why nothing is glowing.** `/elm options` has a
  new section listing every bar addon Elmira can use — ElvUI, Bartender4, Dominos and the default
  Blizzard bars — and saying which one it is actually using, in words. If you have two installed it
  says which one won. A **Preview glow** button flashes the button for your current suggestion on
  demand, so you can check the effect standing in a city instead of waiting for a fight. And a
  per-spell check walks the things that have to be true — the spell is on a bar, that button is on
  screen right now, the glow is switched on, and Elmira is showing at all — and names the one that
  is not, with what to do about it. It tells apart the cases that look identical from the outside:
  a spell you never dragged onto a bar, a button hidden by your current stance, and the three
  separate switches that can leave a perfectly placed button dark. Pick any spell in your playstyle
  to check, not just the one being suggested.
- "Also glow your action bar" has moved from Glow to Action Bars, next to the list that shows you
  whether it is working.
- **One addon folder.** Elmira used to install as five: the addon plus `Elmira_ElvUI`,
  `Elmira_ItemRack`, `Elmira_WoWSims` and `Elmira_Insights`. Everything that did something is now
  inside Elmira itself, so there is one box to tick in the AddOns list, one thing to update, and one
  version number. The WoWSims and Insights folders are gone entirely — they were placeholders that
  did nothing, and they will come back when they do something. If you have any of the old folders in
  your AddOns directory you can delete them. Third-party class packs are unaffected.
- **Bartender4 bars now glow, and so do Dominos'.** Elmira only knew how to find buttons on ElvUI's
  bars. It turns out ElvUI and Bartender4 build their buttons the same way, so supporting one was
  most of the way to supporting all of them. Whichever you use, Elmira now finds the button holding
  your next suggested spell — and if you use a bar addon it has never heard of, it will still find
  the buttons and simply call it "action bars".
- **Fixed: spells on your last three action bars never glowed.** The scan of Blizzard's default bars
  covered five of the eight bars that exist, missing MultiBar5, 6 and 7 entirely. If your suggested
  spell lived on one of those, nothing lit up and nothing said why.
- **Fixed: a spell placed on certain ElvUI buttons could never glow.** Buttons holding a spell
  directly, rather than an action-bar slot, were skipped when Elmira built its map.
- Fixed: changing stance, form or Shadowform left Elmira looking at the old bar layout, so the glow
  could land on the wrong button or nowhere at all until something else changed. It only affected
  classes that change bars this way, so no paladin ever saw it.
- **Fixed: your cloak and ring runes were never being read.** Elmira looked at seven of the ten
  slots Season of Discovery lets you engrave — helm, chest, belt, legs, boots, wrist and gloves —
  and never at your two rings or your cloak. Any line waiting on a rune in one of those three slots
  stayed silent forever, and the setup window told you to engrave runes you were already wearing.
  All ten slots are read now. Cloak runes are the ones this affected in practice: Righteous
  Vengeance on the Retribution builds, Shield of Righteousness on Protection, and Shock and Awe on
  Shockadin.
- **Fixed: the Shock and Awe rune was stored under the wrong spell.** It held an older version of
  the rune that the game never reports, so the Shockadin lines depending on it could not fire even
  once the cloak was being read. Both halves of that one are now confirmed against a live client.
  Righteous Vengeance, which every Retribution build depends on, was stored under the same kind of
  wrong spell and is fixed too. Both are now confirmed against a live client, along with Sheath of
  Light, where two candidate spells existed and only one turned out to be real.
- **Share a build as a string.** `/elm export` turns the active build (or `/elm export <key>`) into
  an `ELM1:` string and places it in the new Import/Export box under `/elm options`; paste one there,
  or `/elm import <string> [name]`, and it becomes one of your own builds — `/elm profile USER_…`
  switches to it. Every shipped build round-trips exactly; an imported build is checked against your
  class's data before it is accepted, and a line whose condition was hand-written code arrives
  switched off rather than silently unconditional. Your builds live account-wide and remember which
  shipped build they came from.
- Fixed: the queue could suggest Avenging Wrath or Aura Mastery again a slot after suggesting them —
  in `/elm debug queue` always, and in the live queue the first time each session, before the client had
  reported their cooldown. Both now carry their cooldowns (3 and 2 minutes) so the preview knows
  them from the start.
- **New playstyle: Shockadin (experimental).** The Holy caster: Holy Shock and Exorcism on cooldown,
  Judgement of Righteousness, Crusader Strike when runed, and with the Holy T3.5 4-set, three Holy
  Power spent on Holy Shock or Divine Storm. No published Phase 8 guide exists for this build — the
  only one is from Phase 2 — so this rotation is Elmira's own reasoning from the set bonuses and the
  spell coefficients, and the setup window marks it experimental. Two-handers scale best with the
  6-set, so the old one-hander requirement is gone.
- **Exodin gains its execute.** Hammer of Wrath is now in the Exodin queue when the target is below
  20% health — it was missing entirely. With the Improved Hammer of Wrath wrist rune it becomes
  instant and self-resetting under 10%, but that rune shares the wrist with Purifying Power, so the
  choice stays yours. Soul of the Justicar is now recognised as granting the same Judgement effect as
  the Draconic 2-set, so Judgement goes on cooldown for its wearers too.
- **New playstyle: Protection.** The sword-and-board tank: keep Holy Shield and Righteous Fury up,
  Seal of Martyrdom on, then Hammer of the Righteous, Shield of Righteousness, Exorcism and Avenger's
  Shield on cooldown, Judgement as the filler. It needs its runes — Hand of Reckoning is the only taunt
  a paladin has — and the setup window lists exactly which to engrave. Taunt and Divine Protection are
  yours to call: Elmira cannot see threat or your health, so it will not guess for you. Sourced from
  Wowhead's Phase 8 tank guides.
- **New playstyle: Wrath-like.** The relaxed Retribution build — one seal, a slow two-hander, and a
  simple priority: Divine Storm at 3 Holy Power once you have the T3.5 4-set, Crusader Strike and
  Exorcism (your shoulder soul decides which comes first), Judgement as the filler. Sourced from
  Wowhead's Phase 8 guide, and like every playstyle it adapts to the sets and soul you are actually
  wearing. The setup window will offer itself once more so you can see it.
- **The setup window now tells you which runes to engrave, instead of marking them as missing.**
  In Season of Discovery a playstyle is built around its runes, and they cost 1c at the Rune Broker
  in any starting zone — so a rune you have not engraved yet is a quick errand, not a reason the
  playstyle does not fit you. Each playstyle's row now ends with "Engrave first: …" listing exactly
  the missing ones by name and slot. When Elmira cannot read your runes at all, it says that, rather
  than claiming you lack them.
- **One addon folder instead of two.** Paladin data used to ship as a separate `Elmira_Paladin`
  addon that Elmira loaded on demand. It is now part of Elmira itself, so there is one thing to
  install, one thing to enable and one version number. Nothing changes for you in game: the same
  playstyles, the same queue. If you have an old `Elmira_Paladin` folder in your AddOns directory you
  can delete it. Third-party class packs are unaffected — the public API they register through is
  unchanged, and one installed for your class still takes precedence over the shipped data.
- Fixed: when a class pack failed to load, Elmira said only that it had no data for your class. It
  now says which addon failed and why, and stays quiet when it has shipped data to fall back on.
- `/elm debug perf` now opens with Elmira's own memory instead of the whole client's Lua heap. The
  old line read `lua memory: 327094 KB`, which is every addon you have loaded and made it look as
  though Elmira were using 300 MB. The heap total is still there, labelled as what it is. On a client
  that cannot report per-addon usage it says so, and it now tells that apart from a read that simply
  failed this time.
- `/elm debug perf` also resolves which playstyle is active while the display is hidden, instead of
  reporting none.
- **Every screen-edge cue now has its own colour, edge and intensity.** Previously a cue flared in
  whatever the playstyle suggested and only on the edge it named, which is no use if you want two
  cues on different sides of the screen or you cannot pick that particular red out of your peripheral
  vision. Each change flares once as you make it, because a colour swatch tells you nothing about
  whether you will actually catch it mid-fight. The controls stay greyed out until the cue is on.
- Fixed: a screen-edge cue you turned on during a fight never fired. Elmira remembers which
  suggestion it last flared for, so it does not flash ten times a second while the same spell stays
  on top — but it kept that memory when you enabled a cue, so a cue switched on while its spell was
  already the top suggestion counted as "already shown" and stayed silent. Since that is exactly when
  you turn a cue on, it looked like the feature did nothing. Enabling or disabling a cue now clears
  that memory and repaints, and so does switching build or profile, which had the same flaw.
- `/elm debug cues` says why a screen edge is dark: which cues this build offers, which are on, which
  cannot fire yet and why, whether the cue's spell is the current suggestion, and how long ago each
  one last flared. `/elm debug cues <n>` test-fires one so a silent cue can be told apart from a
  broken display.
- Fixed: the setup window claimed you did not know Seal of Martyrdom even when you did — it was
  checking a list of your spells that was never filled in, so every ability requirement read as
  missing. It now reads your spellbook, and when it genuinely cannot, it says so instead of telling
  you something is wrong.
- **A setup window.** `/elm setup` (or the button in the options) shows what Elmira thinks your
  character is and lists the playstyles that have shipped for your class, recommended first, each
  with what it expects of your gear. A playstyle you do not currently meet is marked, not hidden —
  you can still pick it. Offered once on a new character, and once more if the shipped list changes.
- `/elm profile` lists the builds, says which one is active and why, and pins one.
  `/elm profile auto` hands the choice back to Elmira.
- `/elm advise` tells you what to **change**: which shoulder soul your build wants, which runes it
  expects, and whether the weapon you are holding suits it. Conditional on the gear you actually
  have, and advice only — nothing here changes what the rotation suggests.
- **Elmira now tells you when it cannot find a spell on your bars**, once per spell, instead of
  quietly showing only the queue icon. That failure was invisible before, which is how the rank
  problem lasted a whole build.
- When Elmira cannot read something, it now says so instead of guessing. An unreadable shoulder
  enchant or weapon speed shows as "could not tell", never as "wrong" — so you are never sent to fix
  something that is already fine.
- **Switching your ItemRack set can switch your build.** Map a set name to a playstyle and Elmira
  follows your gear. ItemRack's own internal sets are ignored, so restoring gear after a fight does
  not change anything.
- Elmira now picks a starting build by what your character can actually play, rather than always
  taking the first one in the list — and still falls back gracefully when it cannot tell.
- Elmira can now read your **swing timer** (via LibClassicSwingTimerAPI), which is what seal-twisting
  builds need. Nothing shipped uses it yet — the twist and stacking builds arrive later — but
  `/elm debug swing` shows what it can see, and says why when it cannot see anything: no library, no
  swing observed yet, or a stale reading because you are standing still.
- Suggestions projected a few casts ahead now age the swing timer with them, instead of asking "how
  long until my next swing" and getting the answer for right now.
- The seal-twist window ships as a **sourced** number rather than a remembered one. Blizzard's hotfix
  note says the replaced seal lasts "a short time" and gives no figure, so the 0.4s Elmira uses is
  taken from the wowsims simulator and labelled as such. If it is ever removed, twisting goes inert
  rather than falling back to a guess.
- Fixed: the bar glow missed any spell whose **rank** on your bar differs from the one Elmira ships.
  Classic gives every rank its own spell id, so a bar holding Exorcism (Rank 5) never matched — for
  that spell the glow simply never appeared, with no error anywhere. Buttons are now matched by name
  as well as by id, which has no ranks.
- Fixed: the ElvUI provider's fallback lookup passed the word "action" where a slot number belonged,
  so it found nothing whenever the fast path did not already work.
- **The queue now hides when you are not fighting.** New setting under Display: *Always*, *In
  combat*, or *In combat, or when you have a target* (the default). Until now it was on screen from
  login to logout, glowing your action bar while you stood in a city — there was no setting because
  there was no rule. Hidden also stops the update loop, so a hidden queue costs nothing.
- Fixed: with ElvUI, the bar glow could land on a hidden Blizzard action button. ElvUI hides those
  bars rather than removing them, so Elmira found the spell, glowed the button, and nothing appeared
  on screen. Only buttons that are actually visible are considered now.
- `/elm debug bars` now walks the whole chain — which providers registered, whether ElvUI's button
  library is present and how many buttons it holds, and for each spell in the queue whether a visible
  button was found and which source answered. It used to report only the number of providers, which
  is the one fact that was never the problem.
- The suggestion strip can now actually be moved. `/elm lock` showed the drag panel, but the icons
  sitting on top of the frame swallowed every drag, so the strip could not be moved at all.
- Choosing the **Autocast** glow style no longer breaks the display. It passed Elmira's name into a
  position the glow library expected a number in, and the whole strip stopped updating.
- Hovering an icon now explains the suggestion. The rule's name, the build it came from, and each
  condition in green or red — and for a rule with no conditions, it says so rather than showing you
  the plain spell tooltip and nothing else.
- The strip keeps its unlocked state across a `/reload`, instead of needing `/elm lock` twice to get
  the drag panel back.
- A display error is now reported once instead of on every queue change, so one bug can no longer
  bury a fight in chat.
- Learning mode: one suggestion at a time, larger, with the name of the rule that chose it underneath.
  It sets icons to 1 and scale to 140% and says so, and both stay yours to change afterwards.
- Options at `/elm config` or the minimap button: how many icons, scale, lock, glow style, and
  whether to glow your action bars too.
- Screen-edge cues for the moments you are not looking at the UI. **Off unless you turn one on**,
  one at a time — the build suggests a short list and you pick from it. A cue that cannot fire yet
  is shown greyed out with the reason rather than quietly missing.
- Elmira now glows the button on your ElvUI bars, not just its own icon.
- The addon has its own icon and colour, so its messages no longer look like every other addon's.
- **Elmira now shows you something.** A queue of your next casts appears on screen, largest first,
  with cooldown sweeps and your keybinds. Drag it with `/elm lock`; hover an icon to see why it is
  being suggested. Set how many icons to show, and the scale, in the options.
- `/elm debug perf` reports how much work the display skipped, so a framerate problem is visible
  rather than guessed at.
- Recordings now note what each spell costs, so a suggestion you could not afford can be told apart
  from one that was simply cheap, and mark timestamps are rounded like every other recorded number.
- The Exodin build now lists Seal of Martyrdom as a requirement. It is bought from a book at level 10
  rather than being a rune, so it is easy to reach 60 without it — and without a seal most of the
  rotation has nothing to suggest.
- Exodin now suggests Judgement when nothing better is ready, instead of leaving you with nothing to
  press. This matters most on a fresh level 60 with no runes, who previously had no suggestion for
  most of their globals; at full gear the rest of the rotation still outranks it, so little changes.
- Exodin moves Consecration up when there are 3 or more enemies. Single-target behaviour is
  unchanged. (This has no effect yet — counting nearby enemies arrives in a later milestone.)
- Exodin now judges only in the last 1.5 seconds of your seal rather than the last 3, so the seal is
  kept up longer.
- The recording now names Seal of Martyrdom's damage effect instead of logging an unrecognised spell
  id, and marks it as something the game casts for you rather than something you pressed.
- Recording now captures **what you actually cast**, next to what Elmira was suggesting a moment
  earlier. Until the display lands there is no way to see a suggestion mid-fight and no way to type a
  command during one, so this is the only way to check whether the rotation advice is any good.
- Recorded marks now carry real timestamps. Every mark in every recording so far was stamped zero, so
  a recording could not be read in time order at all.
- Each entry in a recorded mark now says **which condition rejected it** (`buff:VENGEANCE_BUFF`,
  `any(target_type:Undead,rune:RUNE_PURIFYING_POWER)`), and marks now also record your buffs, active
  seal, mana, target, global cooldown and each spell's learned cooldown. Previously a rejected
  suggestion gave no reason and had to be guessed at backwards.
- Recordings hold 120 marks rather than 40. A four-fight session overran the old limit and discarded
  76 snapshots, keeping only the end of the run.
- Recorded numbers are rounded to two decimals, which is all the precision the client has.
- While recording, the addon now samples every 3 seconds during combat. Combat start happens before
  anything is on cooldown and combat end after most have expired, so neither captured the state the
  rotation actually runs in.
- Combat detection now uses the player's actual combat state rather than UI lockdown, which is a
  different thing and lags the start of a fight — previously every recorded mark claimed you were out
  of combat. Recorded marks also no longer collapse a combat transition into the previous mark.
- `/elm rec start` now refuses to begin while you are in combat, and prints the run steps in chat so
  you do not need a document open on another screen. Repeated identical snapshots are no longer
  recorded, so pulling a dummy several times cannot bury the gear states you are comparing.
- Weapon speed now actually reads the item's speed: it lives in the tooltip's right-hand column, which
  the previous attempt did not read, so it had been silently falling back to the haste-modified value.
- Recorded marks no longer lose `false` values — combat state and per-entry "usable" verdicts were
  being saved as "not evaluated" instead of "no".
- `/elm rec start` … `/elm rec stop` records a whole test session — combat start/end and gear swaps
  mark themselves — and one `/reload` writes it all out. Previously each snapshot cost its own reload
  or had to be copied out of the chat frame mid-fight.
- Fixed the suggestion queue advancing no time: every slot was computed for the same instant, so the
  queue after the first suggestion was meaningless. Fixed the queue repeating "cast your seal" five
  times out of combat. Both were only visible on a live character.
- `/elm debug dump` now saves the full queue and each entry's pass/fail verdict to SavedVariables, so
  results no longer have to be copied out of the chat frame mid-fight.
- `/elm debug queue [build] [depth]` prints the live suggestion queue and, beneath it, why each entry
  passed or failed its conditions. Until the display lands this is the only way to see what the
  engine actually decides on a real character.
- Weapon speed is now the base item speed read from the tooltip, not the haste-modified attack speed.
  A weapon with an attack-speed proc previously reported a different speed mid-fight, which could
  flip a build's speed requirement while you were playing.
- M2 gear matrix: every shipped build is now exercised across 11 gear states (no runes, runes only,
  each tier threshold, soul-granted bonuses, best-in-slot), asserting the actual suggestion queue. A
  build that ships without scenarios fails the suite.
- M2 adapter: `Adapters/Vanilla.lua` implements the State contract against the live client — observed
  cooldowns with GCD readings filtered out, rune matching on ability IDs, tooltip-based soul and set
  detection, and `bonus()` resolving a set threshold or a soul interchangeably. `runes` and
  `engraving` are now independent capabilities.
- Verified in game: all seven engraved rune slots now resolve correctly, tooltip scanning works on
  1.15.x (souls and set counts are readable), and the live-vs-shipped cost disagreement is reported.
  Ruled out using soul "hidden auras" for detection — they are not visible to `UnitAura`, so soul
  detection stays tooltip-based and enUS-only in v1.
- Paladin T2.5 4-set reclassified from passive to an aura: it applies **Excommunication** (1217927,
  +36% Exorcism damage, 20s, 3 stacks), so builds can gate on the buff instead of counting set pieces
  (ADR-0004). Its rotation guidance is unchanged — this is not a reason to hold Exorcism.
- Corrected the T2 4-set attribution: 467526 is the Soul of the Judicator effect (Judgement cooldown
  -5s, damage -45%), not Soul of the Retributor.
- `/elm debug dump` now scans for provisional aura IDs and reports whether the client returns them,
  which is the only way to tell whether a "permanent hidden aura" is visible to `UnitAura` at all.
- Data sourcing: IDs for server-side-scripted SoD bonuses may now come from the WoWSims simulator
  source, which is the only place they exist — Wowhead shows those bonuses as a dummy aura and never
  names the buff the player receives. Any such ID ships tagged `verify = "in-game"`, the one
  sanctioned way an ID passes CI without a fetched Wowhead `src`, and `/elm debug dump` lists every
  provisional entry so it cannot sit unresolved. Enforced by `tests/spec/data_sourcing_spec.lua`.
- Paladin T2 Ret set corrected to **Radiant Judgement** (item-set 1810, aliases "Judgement Armor" and
  "Draconic"); its 6-set now names the buff builds actually watch, *Swift Judgement* (467530). The
  T3.5 6-set likewise names *Templar* (1226464), which was previously "id TBD".
- M2 collector: `Adapters/Collector.lua` and `/elm debug dump` write a machine-readable character
  snapshot to SavedVariables. It prints the raw client value beside our interpretation of it — the
  one-sided view is what let a rune-ID bug survive two probe rounds — and reports how many rune slots
  disagree with the shipped data. On demand only; a single snapshot is kept, not a history.
- M2 data: paladin `Spells`/`Sets`/`Souls` IDs verified (102 `UNVERIFIED()` markers down to the M5
  out-of-scope keys). Every `RUNE_*` entry now holds the *ability* ID rather than the teach-spell ID,
  which is what rune detection actually matches; the previous values silently reported "not engraved"
  for runes the player was wearing. `Schema.validate` now rejects a non-numeric spell cost at load.
- Project scaffold (kit v1, 2026-09-01).
- M0 skeleton: addon-family layout (Elmira core + Elmira_Paladin/ElvUI/ItemRack/WoWSims/Insights
  stubs), `Elmira.API` v1 registry, AceDB defaults with `dbVersion` + migrations, `/elm` slash
  (help, debug state|bars|perf, modules, version), busted + luacheck harness with the Core/Adapters
  boundary enforced by `.luacheckrc`. Interface bumped to 11509 across all TOCs. Author: Valermus.
- M1 core: `Core/Schema.lua` (build validation + condition compilation, all 28 condition types from
  docs/02 including `all`/`any`/`not` and the `custom` escape hatch), `Core/Engine.lua`
  (`Engine.pick`), `Core/Simulation.lua` (`Simulation.queue` with a pluggable time step). Added
  `level`, `rune` and `sealLinger` to the State contract so every documented condition has something
  to read. Headless: no in-game behaviour changes yet.
- Overlay reworked before any of it was built (ADR-0009): screen-edge flares are opt-in peripheral
  cues, off by default, firing when the now-slot *changes to* an opted-in spell — not a third mirror
  of "what do I press" alongside the queue and bar glow. `db.profile.overlay` reshaped to
  `{ cues = {} }` accordingly; no migration needed, since the old keys equalled their defaults and
  AceDB never wrote them.
- Fixed: `Elmira_ElvUI` and `Elmira_ItemRack` registered nothing on login. `## LoadWith:` loaded
  them alongside ElvUI/ItemRack, ahead of their own `## Dependencies: Elmira`, so their file
  scope saw a nil `Elmira` global and their guard returned. Both TOCs now rely on hard
  `Dependencies` for ordering, and the guard prints instead of returning silently.
