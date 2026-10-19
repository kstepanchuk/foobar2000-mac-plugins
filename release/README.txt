Плагины для foobar2000 на macOS (foobar2000 для Mac 2.x, Apple Silicon и Intel)

  foo_wave_seekbar.fb2k-component  — Waveform Seekbar 0.5: перемотка по волне трека
  foo_classic_ui.fb2k-component    — Classic UI 0.14: интерфейс как foobar на Windows
  foo_aimp_ui.fb2k-component       — AIMP UI 0.3: интерфейс в стиле AIMP

УСТАНОВКА
1. Перед установкой снимите карантин (иначе macOS может сказать «файл повреждён»).
   Откройте Терминал, перейдите в папку с файлами и выполните:
     xattr -dr com.apple.quarantine *.fb2k-component
2. Дважды кликните по каждому файлу или добавьте их в foobar2000:
   Settings → Components → «+». Перезапустите foobar2000.
3. View → Layout → Edit Layout, вставьте одну из раскладок и нажмите Apply.

РАСКЛАДКА «КАК НА WINDOWS»
splitter horizontal style=thin
 classic-toolbar
 waveform-seekbar
 classic-tabs
 classic-playlist
 classic-statusbar

РАСКЛАДКА «КАК В AIMP»
splitter horizontal style=thin
 aimp-header
 waveform-seekbar time=sides
 aimp-tabs
 aimp-playlist
 aimp-footer
