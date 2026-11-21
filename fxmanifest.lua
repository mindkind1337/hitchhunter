fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hitchhunter'
description 'Finds which resource causes server, network and sync thread hitches: a wrapper injected in every resource times its handlers, threads and callbacks and counts what it sends'
version '1.0.0'

server_scripts {
    'config.lua',
    'server/main.lua',
    'server/host.js',
}

-- inject/server.lua is included by other resources as a shared_script: clients need to be able to load it
-- (it returns at once on the client)
files {
    'inject/server.lua',
}
