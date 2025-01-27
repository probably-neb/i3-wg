build:
    zig build -Doptimize=ReleaseSafe

release-local: build
    cp ./zig-out/bin/i3-wg /home/neb/.local/bin
    
