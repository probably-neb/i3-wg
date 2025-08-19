## Issues in i3-workspace-groups

- Python updates cause it to break
- Initial 1, 1 bugs i.e. not
- changing workspace when another window is in that workspace fails (i.e. moving work:1 to play when play:1 exists does not work)

## Current

- [ ] Transition to using State.Cmd buffer
- [ ] Write tests for do_cmd with constructed args
    - [ ] String representation -> State
    - [ ] Compare string representation of cmd buf to expected output
- [ ] Have groups logical index stored in groups map

## Additional Commands

- [ ] <meta+w> focus arbitrary group with rofi
- [*] Rename grouped workspace (wrapper around `bindsym $mod+r exec i3-input -F 'rename workspace to "%s"' -P 'New name: '`)
- [ ] delete workspace group
- [ ] Move workspace within focused group not active group
- [ ] save group command? (get + parse tree -> save to sqlite or something)

## Issues
- [ ] Fix handling of workspaces with no num like `foo:baz`
- [ ] If moving to group from inactive workspace, make sure active workspace is preserved
- [ ] If no active workspace, should apply fixup to set currently focused workspace as active
- [ ] Identify required "fixups"
    - [ ] Items with no group -> Default
    - [ ] Conflicting group logical indices
- [ ] Nail down when to try and parse name as num "name_num" or i3.name
- [ ] Default to i3-input with no rofi
- [ ] don't create new '2:2' if '2' already exists (Move_Active_Container_To_Workspace)
- [ ] Create README
- [ ] Create ability to merge workspaces (move all containers from one workspace to another)
