if exists("g:mli_cycler_loaded")
  finish
endif
let g:mli_cycler_loaded = 1

let s:bin_path = fnamemodify(resolve(expand('<sfile>:p')), ':h').'/bin/main.exe'
" Build the code in bin/ and then source this file in your vimrc in order to
" use the plugin.

" Goes to the next ml/mli/intf file in the list of ml/mli/intf files for the
" current buffer.
function! s:next()
  call jobstart([s:bin_path, 'next'])
endfunction

" Goes to the next ml/mli/intf file in the list of ml/mli/intf files for the
" current buffer.
function! s:previous()
  call jobstart([s:bin_path, 'prev'])
endfunction

" Displays the list of ml/mli/intf files for the current buffer in an fzf
" explorer.
function! s:list_fzf()
  call jobstart([s:bin_path, 'list-fzf'])
endfunction

" Echoes the list of ml/mli/intf files for the current buffer in the command
" line (useful for exploring, or if you don't have fzf installed).
function! s:list()
  call jobstart([s:bin_path, 'list'])
endfunction

function! s:set_up_commands()
  command! -bar -buffer MliCyclerNext call s:next()
  command! -bar -buffer MliCyclerPrev call s:previous()
  command! -bar -buffer MliCyclerListFzf call s:list_fzf()
  command! -bar -buffer MliCyclerList call s:list()
endfunction

augroup mli_cycler
  autocmd!
  autocmd FileType ocaml call s:set_up_commands()
augroup END
