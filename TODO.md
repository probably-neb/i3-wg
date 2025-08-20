## Issues in i3-workspace-groups

- Python updates cause it to break
- Initial 1, 1 bugs i.e. not
- changing workspace when another window is in that workspace fails (i.e. moving work:1 to play when play:1 exists does not work)

## Cleanup/Improvements

- [ ] Have groups logical index stored in groups map
- [?] Extract arg parsing to fat struct of args
    - pro: makes `do_cmd` fully stateless
    - con: makes codepaths less clear
- [ ] Extract active group changing to function

## Additional Commands

- [ ] <meta+w> focus arbitrary group with rofi
- [ ] Make focused group active
    - No args
    - Pairs well with focus arbitrary group, and `--follow`
    - switch workspace/container to group, follow, then hit third keybind to focus
- [*] Rename grouped workspace (wrapper around `bindsym $mod+r exec i3-input -F 'rename workspace to "%s"' -P 'New name: '`)
- [ ] delete workspace group
- [ ] Move workspace within focused group not active group
- [ ] save group command? (get + parse tree -> save to sqlite or something)

## Issues
- [ ] Need a `--follow` flag or something
    - Also a `--when-focusing-a-new-group-auto-set-it-as-the-active-group`
- [ ] Assign workspace to group
- [ ] Fix handling of workspaces with no num like `foo:baz`
- [ ] If moving to group from inactive workspace, make sure active workspace is preserved
- [ ] If no active workspace, should apply fixup to set currently focused workspace as active
- [ ] Identify required "fixups"
    - [ ] Items with no group -> Default
    - [ ] Conflicting group logical indices
- [ ] Nail down when to try and parse name as num "name_num" or i3.name
- [ ] Default to i3-input with no rofi
- [ ] Create README
- [ ] Create ability to merge workspaces (move all containers from one workspace to another)
    - [ ] First step: Just find hole
