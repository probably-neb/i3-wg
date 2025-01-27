# I3-WG

## I3 Workspace Groups

`i3-wg` is a rewrite of the [i3-workspace-groups](https://github.com/infokiller/i3-workspace-groups) project.

It is currently a work in progress and is missing some features of the original project (see [TODO.norg](./TODO.norg)), however, I have personally completely switched over to using it

## Why?

I was a big fan of `i3-workspace-groups` and used it for over a year. However, I had a few problems with it.

Those being:

A. Because the original project was implemented in python, system Python updates often broke it.
B. The system it used to group workspaces often broke in weird and opaque ways. E.g.
    - The initial default workspaces i3 created would never be used. If I started working in workspace 1, focusing workspace 1 would focus a new workspace also named 1 instead of the one I was already working in
    - Often groups and workspaces would not be ordered correctly, i.e. `work:1` would appear after `work:2`. And groups would not always be ordered by last used.
C. The performance while fast enough, was often noticeably slow. Especially after creating this rewrite, I notice how much snappier switching groups and workspaces is
D. I had a few additional features I felt would be useful in my workflow, however, attempting to add them to the original in a fork ended up being far more complicated than anticipated. As the code was hard to understand and reason about.
E. Inflexibility. Many commands were not as flexible as I felt they should be, and many did not behave as I would expect them to E.g.
    - Unable to move a container/workspace around in a non active group
    - Unable to move containers/worksapaces to a workspace in a different group that already existed (and contained other containers)

Given these issues, I decided the best course of action was to rewrite the project in a compiled language that would allow me to use a binary for distribution, ideally with increased performance. For this I decided to use Zig.

I was also able to use what implementation details I was able to decipher from the original implementation to simplify the implementation and as of right now, I am at near feature parity with the original in a single main.zig file that contains far less lines of code than the original even though Zig can be quite verbose (explicit).


## Usage

Better documentation will be coming soon, as well as a `--help` flag for the CLI.

Just as in the original project, this implementation relies on `rofi` for select menu functionality.
Most (but the plan is to have all) commands fallback to a select style menu using `rofi` if explicit parameters are not provided.
This also means that most (but the plan is to have all) commands can take explicit parameters rather than relying on `rofi`.
Therefore you should be able to make due without `rofi` if you never create arbitrary workspace groups or switch to arbitrary workspaces.

As of right now this is what the `i3-wg` portion of my `i3/config` looks like:

```
# i3-workspace-groups

set $exec_i3_groups exec --no-startup-id ~/.local/bin/i3-wg

# Switch active workspace group
bindsym $mod+g $exec_i3_groups switch-active-workspace-group

# Assign workspace to a group
bindsym $mod+Shift+g $exec_i3_groups assign-workspace-to-group

# Select workspace to focus on
bindsym $mod+w $exec_i3_groups focus-workspace

# Move the focused container to another workspace
bindsym $mod+Shift+w $exec_i3_groups move-active-container-to-workspace

# (NOTE: NOT IMPLEMENTED YET) Rename/renumber workspace. Uses Super+Alt+n 
# bindsym Mod1+Mod4+n $exec_i3_groups rename-workspace

bindsym $mod+1 $exec_i3_groups focus-workspace 1
bindsym $mod+2 $exec_i3_groups focus-workspace 2
bindsym $mod+3 $exec_i3_groups focus-workspace 3
bindsym $mod+4 $exec_i3_groups focus-workspace 4
bindsym $mod+5 $exec_i3_groups focus-workspace 5
bindsym $mod+6 $exec_i3_groups focus-workspace 6
bindsym $mod+7 $exec_i3_groups focus-workspace 7
bindsym $mod+8 $exec_i3_groups focus-workspace 8
bindsym $mod+9 $exec_i3_groups focus-workspace 9
bindsym $mod+0 $exec_i3_groups focus-workspace 10

bindsym $mod+Shift+1 $exec_i3_groups move-active-container-to-workspace 1
bindsym $mod+Shift+2 $exec_i3_groups move-active-container-to-workspace 2
bindsym $mod+Shift+3 $exec_i3_groups move-active-container-to-workspace 3
bindsym $mod+Shift+4 $exec_i3_groups move-active-container-to-workspace 4
bindsym $mod+Shift+5 $exec_i3_groups move-active-container-to-workspace 5
bindsym $mod+Shift+6 $exec_i3_groups move-active-container-to-workspace 6
bindsym $mod+Shift+7 $exec_i3_groups move-active-container-to-workspace 7
bindsym $mod+Shift+8 $exec_i3_groups move-active-container-to-workspace 8
bindsym $mod+Shift+9 $exec_i3_groups move-active-container-to-workspace 9
bindsym $mod+Shift+0 $exec_i3_groups move-active-container-to-workspace 10
```
