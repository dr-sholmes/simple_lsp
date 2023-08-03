" Start the LSP server process and connect vim
function! LSPStartServer(command, root_path)
    return simple_lsp#StartServer(a:command, a:root_path)
endfunction

" Register the current buffer with the LSP. Once registered vim will notify
" the LSP server of changes to the buffer. When the buffer is deleted vim will
" notify the LSP server.
function! LSPRegisterBuffer()
    return simple_lsp#RegisterBuffer()
endfunction

" Request location of declaration for the entity under the cursor
function! LSPRequestDeclaration()
    return simple_lsp#RequestDeclaration()
endfunction

" Request location of references to the entity under the cursor
function! LSPRequestReferences()
    return simple_lsp#RequestReferences()
endfunction

" Request hover information for the cursor location
function! LSPRequestHover()
    return simple_lsp#RequestHover()
endfunction

" Request completions for the current cursor location (WIP)
function! LSPRequestCompletion()
    return simple_lsp#RequestCompletion()
endfunction

function! LSPGetDiagnostics()
    return simple_lsp#GetDiagnostics()
endfunction
