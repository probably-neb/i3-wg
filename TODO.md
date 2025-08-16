## Issues in i3-workspace-groups

- Python updates cause it to break
- Initial 1, 1 bugs i.e. not
- changing workspace when another window is in that workspace fails (i.e. moving work:1 to play when play:1 exists does not work)

## Current

- [ ] Make do_cmd take in Cli_Cmd_w/_args
- [ ] Write tests for do_cmd with mocked socket and constructed cmd
- [ ] Clean

## Additional Commands

- [ ] <meta+w> focus arbitrary group with rofi
- [*] Rename grouped workspace (wrapper around `bindsym $mod+r exec i3-input -F 'rename workspace to "%s"' -P 'New name: '`)
- [ ] delete workspace group
- [ ] Move workspace within focused group not active group
- [ ] save group command? (get + parse tree -> save to sqlite or something)

## Issues
   - [ ] Default to i3-input with no rofi
   - [ ] don't create new '2:2' if '2' already exists (Move_Active_Container_To_Workspace)
   - [ ] Create README
