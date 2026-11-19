# Changelog

## 0.3.1 (2026-11-19)

- **Focus Guard says when a browser is blocked.** If macOS won't let Notch ask Chrome or Safari for
  its tab, the Focus Guard menu shows ⚠︎ with a link to the right System Settings page, instead
  of failing silently. Adds a log and `notch://guard-check` for diagnosing it.
- **Public, all rights reserved.** Added a LICENSE (view only; no license granted); personal
  references removed from the code, notes and sample data.

## 0.3.0 (2026-11-19)

- **The open panel is redesigned.**
  - **Now leads:** the card you're doing, in full, with Done and Focus.
  - **Up next:** meetings and tasks share one full-width, time-ordered list, at most four rows with an "N more" row.
  - **Height:** the panel is as tall as its content.
- **Compact wings when closed:** an icon and a short value, like the Dynamic Island's compact view.
  - Wings step aside when you reach for a menu under them.
  - Only the notch itself opens the panel.
- **Up next** is whichever comes first in time, the next meeting or the next timed task, with an icon in front.
- **Springs** drive the open and close motion: open in 0.42 s with a slight settle, close in 0.3 s with no bounce.
- **Focus Guard** (opt-in): nudges back to work after 15 minutes on video, games or feeds during the workday, or after 1 minute in a focus round. Reads only the front app and, for Chrome and Safari, the active tab's site.
- **Planner:**
  - Morning: settle leftovers, then pick up to 3 against your free time with a 20% buffer.
  - Evening: wrap up with a note for tomorrow.
  - Focus time is logged per task.
- **Kanban board:** To Do / Doing / Done with drag and drop and a Doing limit of 3.
- **New icon:** the notch opening, as three layers of glass on an orange tile.
- **Credit** in the About window.
- **Sharing:** a universal zip (Apple Silicon and Intel), with the how-to-open note beside it.

## 0.2.0 (2026-11-19)

- **Full task system:** projects, subtasks, deadlines, reminders, repeats, priority, tags, dependencies.
- **Glance:** wings beside the camera, and banners that drop from the notch.
- **Pomodoro** focus rounds with auto-starting breaks; focus mode in orange.
- First shared build.

## 0.1.0 (2026-11-19)

- The notch panel: day status, upcoming events, a simple task list, and a focus timer.
