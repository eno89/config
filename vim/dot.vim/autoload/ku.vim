" ku - Support to do something
" Version: 0.0.0
" Copyright: Copyright (C) 2008 kana <http://nicht.s8.xrea.com/>
" License: MIT license (see <http://www.opensource.org/licenses/mit-license>)
" $Id$  "{{{1
" FIXME: s:choose_action_for_item(): Customizability on keys to choose.
"        - do mapping like Vim's one?
"        - separate 'actions' into a list of 'key'->'name' and a dictionary of
"          'name'->'action', then modify the former list by the user?
"        - BTW, should the former list be a list?  how about to use dict?
" FIXME: auto-complete 1 component for each typing '/' (like bluewind).
" FIXME: s:do(): Force action on unmatched pattern.
" FIXME: more smart sorting:
"        - considering last component.
"        - type buffer: full path vs. relative path.
"        - put garbage files (for example, "foo~") at the last.
" FIXME: review on case sensitivity.
" FIXME: alternative implementation (getchar()), if necessary.
"
" Variables and Constants  "{{{1
" Script-local  "{{{2

let s:FALSE = 0
let s:TRUE = !s:FALSE

let s:TYPE_NUMBER = type(0)
let s:TYPE_STRING = type('')
let s:TYPE_FUNCTION = type(function('function'))
let s:TYPE_LIST = type([])
let s:TYPE_DICTONARY = type({})


" Flag which indicates whether the ku window is opened with bang (:Ku!).
" Possible values are '' or '!'.
let s:bang = ''

" The buffer number of the ku buffer.
let s:INVALID_BUFNR = -3339
  " to be reloadable (for debugging)
if exists('s:bufnr') && s:bufnr != s:INVALID_BUFNR
  execute s:bufnr 'bwipeout'
endif
let s:bufnr = s:INVALID_BUFNR

" Preferred type of items.
let s:INVALID_TYPE = '*all*'
let s:preferred_type = s:INVALID_TYPE

" Key sequence to start (omni) completion
" without auto-selecting the first match.
let s:KEYS_TO_START_COMPLETION = "\<C-x>\<C-o>\<C-p>"

" The last column of the cursor.
let s:INVALID_COL = -3338
let s:last_col = s:INVALID_COL

" Items gathered by the last completion.
let s:last_items = []

" All available types.
if !exists('s:types')
  let s:types = {}
endif

" The prompt for user input.
" This is necessary to publish CursorMovedI event for each typing.
" Note that the length should be 1 to avoid some problems.
let s:PROMPT = '>'

" Misc. values to restore the original state.
let s:completeopt = ''
let s:ignorecase = ''
let s:winrestcmd = ''




" Global  "{{{2
" Flag for debugging.
if !exists('g:ku_debug_p')
  let g:ku_debug_p = s:FALSE
endif

" Patterns for junk items.  These items are listed at the last.
" FIXME: How about g:ku_important_item_pattern?
if !exists('g:ku_junk_item_pattern')
  let g:ku_junk_item_pattern = '\(\~\|\.o\|\.swp\)$'
endif

" Flag to use the type of items for sorting without s:preferred_type.
if !exists('g:ku_sort_by_type_first_p')
  let g:ku_sort_by_type_first_p = s:TRUE
endif








" Interfaces  "{{{1
function! ku#start(bang, type) abort  "{{{2
  " Save/Set up several values.
  let s:bang = a:bang
  let s:preferred_type = s:valid_type_name_p(a:type) ? a:type : s:INVALID_TYPE

  let s:completeopt = &completeopt
  set completeopt+=menuone
  let s:ignorecase = &ignorecase
  set ignorecase
  let s:winrestcmd = winrestcmd()

  " Open a new window and switch to the ku buffer.
  if !s:ku_buffer_exists_p()
    topleft new
    call s:initialize_ku_buffer()
    let s:bufnr = bufnr('')
  else
    execute 'topleft' s:bufnr 'sbuffer'
  endif
  2 wincmd _

  " Do some initialization for each type.
  for type_name in keys(s:types)
    call s:types[type_name].initialize()
  endfor

  " Start Insert mode.
  % delete _
  call append(1, '')
  normal! 2G
  call feedkeys('i', 'n')
endfunction




function! ku#default_key_mappings()  "{{{2
  call s:remap('<C-c>', '<Plug>(ku-cancel)')
  call s:remap('<C-m>', '<Plug>(ku-do-default)')
  call s:remap('<C-i>', '<Plug>(ku-choose-action)')
  call s:remap('<C-j>', '<Plug>(ku-next-type)')
  call s:remap('<C-k>', '<Plug>(ku-previous-type)')
endfunction




function! ku#register_type(args)  "{{{2
  " See s:valid_type_definition_p() for the detail of a:args.
  if !s:valid_type_definition_p(a:args)
    echohl ErrorMsg
    echomsg 'Invalid type definition:' string(a:args)
    echohl None
    return s:FALSE
  endif

  let s:types[a:args.name] = a:args

  return s:TRUE
endfunction




function! ku#unregister_type(name)  "{{{2
  if has_key(s:types, a:name)
    call remove(s:types, a:name)
  endif
  return s:TRUE
endfunction




function! ku#bang()  "{{{2
  return s:bang
endfunction








" Core  "{{{1
function! s:end()  "{{{2
  if s:end_locked_p
    return
  endif
  let s:end_locked_p = s:TRUE

  let n = winnr('#') - 1

  close

  let &completeopt = s:completeopt
  let &ignorecase = s:ignorecase
  execute n 'wincmd w'
  execute s:winrestcmd

  let s:end_locked_p = s:FALSE
endfunction
let s:end_locked_p = s:FALSE




function! s:complete(findstart, base)  "{{{2
  " items = a list of items
  " item = a dictionary as described in :help complete-items.
  "        '^_ku_.*$' - additional keys used by ku.
  "        '^_{type}_.*$' - additional keys used by type {type}.
  if a:findstart
    let s:last_items = []
    return 0
  else
    let s:last_items = []
    let pattern = (s:contains_the_prompt_p(a:base)
      \            ? a:base[len(s:PROMPT):]
      \            : a:base)
    for type_name in (s:preferred_type ==# s:INVALID_TYPE
      \               ? keys(s:types) : [s:preferred_type])
      let new_items = s:types[type_name].gather(pattern)
      for new_item in new_items
        let new_item['_ku_type'] = s:types[type_name]
        let new_item['_ku_sort_priority']
          \ = [
          \     (match(new_item.word, g:ku_junk_item_pattern) < 0 ? 0 : 1),
          \     (g:ku_sort_by_type_first_p ? type_name : 0),
          \     s:match(new_item.word, s:make_asis_regexp(pattern)),
          \     match(new_item.word, s:make_skip_regexp(pattern)),
          \     new_item.word,
          \     (!g:ku_sort_by_type_first_p ? type_name : 0),
          \   ]
      endfor
      call extend(s:last_items, new_items)
    endfor

    call filter(s:last_items, '0 <= v:val._ku_sort_priority[3]')
    call sort(s:last_items, function('s:compare_items'))
    return s:last_items
  endif
endfunction


function! s:compare_items(a, b)
  return s:compare_lists(a:a._ku_sort_priority, a:b._ku_sort_priority)
endfunction

function! s:compare_lists(a, b)
  " Assumption: len(a:a) == len(a:b)
  for i in range(len(a:a))
    if a:a[i] < a:b[i]
      return -1
    elseif a:a[i] > a:b[i]
      return 1
    endif
  endfor
  return 0
endfunction




function! s:do(choose_p)  "{{{2
  let item = s:guess_the_appropriate_item()

  " To avoid doing some actions on this buffer and/or this window, close the
  " ku window.
  call s:end()

  " Do the specified aciton.
  if type(item) == s:TYPE_DICTONARY
    let ActionFunction
      \ = (a:choose_p
      \    ? s:choose_action_for_item(item)
      \    : item._ku_type.actions[item._ku_type.keys['*default*']])
    call s:apply(ActionFunction, [item])
  endif
endfunction




function! s:switch_preferred_type(d)  "{{{2
  let type_names = sort(keys(s:types))
  call insert(type_names, s:INVALID_TYPE, 0)

  let s:preferred_type = type_names[
    \   (index(type_names, s:preferred_type) + a:d + len(type_names))
    \   % len(type_names)
    \ ]
endfunction




function! s:on_InsertEnter()  "{{{2
  let s:last_col = s:INVALID_COL
  return s:on_CursorMovedI()
endfunction




function! s:on_CursorMovedI()  "{{{2
  " Calling setline() has a side effect to the cursor.  If the cursor beyond
  " the end of line (i.e. getline('.') < col('.')), the cursor will be move at
  " the last character of the current line after calling setline().
  let c0 = col('.')
  call setline(1, '')  " dummy setting to know whether the cursor is moved.
  let c1 = col('.')
  call setline(1, printf('type=%s', s:preferred_type))

  " The order of these conditions are important.
  if !s:contains_the_prompt_p(getline('.'))
    let keys = repeat("\<Right>", len(s:PROMPT))
    call s:complete_the_prompt()
  elseif col('.') <= len(s:PROMPT)
    " The cursor is inside the prompt.
    let keys = repeat("\<Right>", len(s:PROMPT) - col('.') + 1)
  elseif len(getline('.')) < col('.') && col('.') != s:last_col
    " New character is inserted.
    let keys = s:KEYS_TO_START_COMPLETION
  else
    let keys = ''
  endif

  let s:last_col = col('.')
  return (c0 != c1 ? "\<Right>" : '') . keys
endfunction








" Misc.  "{{{1
function! s:SID_PREFIX()  "{{{2
  return matchstr(expand('<sfile>'), '<SNR>\d\+_')
endfunction




function! s:nop(...)  "{{{2
  return
endfunction




function! s:string(s)  "{{{2
  " like strtrans(), but convert into more human-readable notation on special
  " keys such as <Left>.
  return strtrans(a:s)  " FIXME: NIY.
endfunction




function! s:initialize_ku_buffer()  "{{{2
  " The current buffer is the ku buffer which is not initialized yet.

  " Basic settings.
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nobuflisted
  let &l:omnifunc = s:SID_PREFIX() . 'complete'
  silent file `='*ku*'`

  " Autocommands.
  autocmd InsertEnter <buffer>  call feedkeys(<SID>on_InsertEnter(), 'n')
  autocmd CursorMovedI <buffer>  call feedkeys(<SID>on_CursorMovedI(), 'n')
  autocmd BufLeave <buffer>  call <SID>end()
  autocmd WinLeave <buffer>  call <SID>end()
  autocmd TabLeave <buffer>  call <SID>end()

  " Mappings.
  nnoremap <buffer> <silent> <Plug>(ku-cancel)
         \ :<C-u>call <SID>end()<Return>
  nnoremap <buffer> <silent> <Plug>(ku-do-default)
         \ :<C-u>call <SID>do(0)<Return>
  nnoremap <buffer> <silent> <Plug>(ku-choose-action)
         \ :<C-u>call <SID>do(1)<Return>
  nnoremap <buffer> <silent> <Plug>(ku-next-type)
         \ :<C-u>call <SID>switch_preferred_type(1)<Return>
  nnoremap <buffer> <silent> <Plug>(ku-previous-type)
         \ :<C-u>call <SID>switch_preferred_type(-1)<Return>

  nnoremap <buffer> <silent> <Plug>(ku-%-enter-insert)  a
  inoremap <buffer> <silent> <Plug>(ku-%-leave-insert)  <Esc>
  inoremap <buffer> <silent> <Plug>(ku-%-accept-completion)  <C-y>
  inoremap <buffer> <silent> <Plug>(ku-%-cancel-completion)  <C-e>

  imap <buffer> <silent> <Plug>(ku-cancel)
     \ <Plug>(ku-%-leave-insert)<Plug>(ku-cancel)
  imap <buffer> <silent> <Plug>(ku-do-default)
     \ <Plug>(ku-%-accept-completion)
     \<Plug>(ku-%-leave-insert)
     \<Plug>(ku-do-default)
  imap <buffer> <silent> <Plug>(ku-choose-action)
     \ <Plug>(ku-%-accept-completion)
     \<Plug>(ku-%-leave-insert)
     \<Plug>(ku-choose-action)
  imap <buffer> <silent> <Plug>(ku-next-type)
     \ <Plug>(ku-%-cancel-completion)
     \<Plug>(ku-%-leave-insert)
     \<Plug>(ku-next-type)
     \<Plug>(ku-%-enter-insert)
  imap <buffer> <silent> <Plug>(ku-previous-type)
     \ <Plug>(ku-%-cancel-completion)
     \<Plug>(ku-%-leave-insert)
     \<Plug>(ku-previous-type)
     \<Plug>(ku-%-enter-insert)

  inoremap <buffer> <expr> <BS>  pumvisible() ? "\<C-e>\<BS>" : "\<BS>"
  imap <buffer> <C-h>  <BS>
  " <C-n>/<C-p> ... Vim doesn't expand these keys in Insert mode completion.

  " User initialization.
  silent doautocmd User KuBufferInitialize
  if !exists('#User#KuBufferInitialize')
    call ku#default_key_mappings()
  endif
endfunction




function! s:ku_buffer_exists_p()  "{{{2
  return (s:bufnr != s:INVALID_BUFNR) && bufexists(s:bufnr)
endfunction




function! s:map(re_p, lhs, rhs)  "{{{2
  for mode in ['n', 'i']  " FIXME: should include other modes?
    execute mode.(a:re_p ? 'map' : 'noremap') '<buffer> <silent>' a:lhs a:rhs
  endfor
endfunction


function! s:remap(lhs, rhs)
  return s:map(s:TRUE, a:lhs, a:rhs)
endfunction


function! s:noremap(lhs, rhs)
  return s:map(s:FALSE, a:lhs, a:rhs)
endfunction




function! s:match(s, pattern)  "{{{2
  let NUM_MAX = 2147483647  " FIXME: valid value.
  let i = match(a:s, a:pattern)
  return 0 <= i ? i : NUM_MAX
endfunction




function! s:make_asis_regexp(s)  "{{{2
  " FIXME: case sensitivity
  return '\c\V' . substitute(substitute(a:s, '\s\+', ' ', 'g'), '\', '\\', 'g')
endfunction




function! s:make_skip_regexp(s)  "{{{2
  " FIXME: case sensitivity
  " FIXME: path separator assumption
  let p_asis = s:make_asis_regexp(substitute(a:s, '/', ' / ', 'g'))
  return substitute(p_asis, '\s', '\\.\\*', 'g')
endfunction




function! s:complete_the_prompt()  "{{{2
  call setline('.', s:PROMPT . getline('.'))
endfunction




function! s:contains_the_prompt_p(s)  "{{{2
  return len(s:PROMPT) <= len(a:s) && a:s[:len(s:PROMPT) - 1] ==# s:PROMPT
endfunction




function! s:guess_the_appropriate_item()  "{{{2
  " If there are two or more items which have the same 'word', the first item
  " appeared in s:last_item will be choosen.  Because it's not possible to
  " know which item was selected in ins-completion-menu.  (It's possible if
  " some keys (<C-n>, <C-p> and others) are mapped when pumvisible(), but Vim
  " doesn't expand such mappings).
  "
  " But the types of such items are usually different, and s:preferred_type can
  " be used to avoid this problem.
  "
  " Another idea is merging actions of same 'word' items.
  " But it seems to be dirty.

  let line = getline('.')
  if len(s:last_items) == 0
    " There is no item which matches to the user input pattern.
    " So return the user input pattern instead of any item.
    let item = line
  elseif s:contains_the_prompt_p(line)
    " User seems to choose the first item in the completion list.
    let item = s:last_items[0]
  else
    " User seems to choose an item in the completion list, and the line is
    " altered by the completion list.
    for i in s:last_items
      if line ==# i.word
        break
      endif
    endfor
    let item = (line ==# i.word ? i : 0)
  endif

  return item
endfunction




function! s:choose_action_for_item(item)  "{{{2
  call s:show_available_actions_message(a:item)

  let c = nr2char(getchar())
  redraw  " clear the menu message lines to avoid hit-enter prompt.

  if has_key(a:item._ku_type.keys, c)
    let name = a:item._ku_type.keys[c]
    if has_key(a:item._ku_type.actions, name)
      return a:item._ku_type.actions[name]
    endif
  endif

  echo 'The key' s:string(c) 'is not associated with any action'
     \ '-- nothing happened.'
  return function('s:nop')
endfunction




function! s:show_available_actions_message(item)  "{{{2
  let items = items(a:item._ku_type.keys)
  call map(items, '[v:val[1], v:val[0]]')
  call sort(items)
  call filter(items, 'v:val[1] !=# "*default*"')
  let keys = map(copy(items), 'v:val[1]')
  let names = map(copy(items), 'v:val[0]')
  let max_key_length = max(map(copy(keys), 'len(s:string(v:val))'))
  let max_name_length = max(map(copy(names), 'len(v:val)'))
  let padding = 3
  let max_cell_length = max_key_length + 3 + max_name_length + padding
  let format = '%*s%*s - %-*s'

  let max_column = max([1, (&columns + padding - 1) / max_cell_length])
  let max_column = min([max_column, 4])
  let n = len(items)
  let max_row = n / max_column + (n % max_column != 0)

  echo printf('Available actions for %s (type %s) are:',
     \        a:item.word, a:item._ku_type.name)
  for r in range(max_row)
    let i = r
    echo ''
    while i < n
      echon printf(format,
          \        (i == r ? 0 : padding), '',
          \        max_key_length, s:string(items[i][1]),
          \        max_name_length, items[i][0])
      let i += max_row
    endwhile
  endfor
  echo ''
endfunction




function! s:valid_type_name_p(name)  "{{{2
  for type_name in keys(s:types)
    if a:name ==# type_name
      return s:TRUE
    endif
  endfor
  return s:FALSE
endfunction




function! s:valid_type_definition_p(args)  "{{{2
  if type(a:args) != s:TYPE_DICTONARY
    return s:FALSE
  endif

  " -- 'name'
  if !s:has_valid_entry(a:args, 'name', s:TYPE_STRING)
    return s:FALSE
  endif
  if !(a:args.name =~# '^[a-z]\+$') | return s:FALSE | endif

  " -- 'gather'
  if !s:has_valid_entry(a:args, 'gather', s:TYPE_FUNCTION)
    return s:FALSE
  endif

  " -- 'initialize'
  if has_key(a:args, 'initialize')
    if !(type(a:args.initialize) == s:TYPE_FUNCTION) | return s:FALSE | endif
  else
    let a:args.initialize = function('s:nop')
  endif

  " -- 'keys'
  if !s:has_valid_entry(a:args, 'keys', s:TYPE_DICTONARY)
    return s:FALSE
  endif
  for k in keys(a:args.keys)
    if !(type(k) == s:TYPE_STRING && type(a:args.keys[k]) == s:TYPE_STRING)
      return s:FALSE
    endif
  endfor
  if !has_key(a:args.keys, '*default*')
    return s:FALSE
  endif

  " -- 'actions'
  if !s:has_valid_entry(a:args, 'actions', s:TYPE_DICTONARY)
    return s:FALSE
  endif
  for k in keys(a:args.actions)
    if !(type(k) == s:TYPE_STRING && s:callable_p(a:args.actions[k]))
      return s:FALSE
    endif
  endfor
  if !has_key(a:args.actions, a:args.keys['*default*'])
    return s:FALSE
  endif


  " -- other entries --

  return s:TRUE
endfunction




function! s:has_valid_entry(dict, key, type)  "{{{2
  return has_key(a:dict, a:key) && type(a:dict[a:key]) == a:type
endfunction




function! s:callable_p(obj)  "{{{2
  return (type(a:obj) == s:TYPE_FUNCTION)
       \ || ((type(a:obj) == s:TYPE_DICTONARY) && has_key(a:obj, '__call__'))
endfunction




function! s:apply(obj, args)  "{{{2
  if type(a:obj) == s:TYPE_FUNCTION
    return call(a:obj, a:args)
  elseif type(a:obj) == s:TYPE_DICTONARY && has_key(a:obj, '__call__')
    return call(a:obj.__call__, a:args, a:obj)
  else
    throw 'This object is not callable:' string(a:obj)
  endif
endfunction




function! s:pa(f, ...)  "{{{2
  " pa = Partial Apply
  " Returns a callable object g,
  " where g(b, ...) is equivalent to f(a, ..., b, ...).
  let g = {}
  let g.f = a:f
  let g.args = copy(a:000)  " a:000 will be lost after this execution.
  function! g.__call__(...)
    return call(self.f, self.args + a:000)
  endfunction
  return g
endfunction








" Built-in Types  "{{{1
" common definitions  "{{{2
function! s:_type_any_action_ex(item)
  call feedkeys(':', 'n')
  call feedkeys(ku#bang(), 'n')
  call feedkeys(' ', 'n')
  call feedkeys(a:item.word, 'n')
  call feedkeys("\<C-b>", 'n')
endfunction




" buffer  "{{{2
" FIXME: how about unlisted buffers?
let s:_type_buffer_cached_items = []
let s:_type_buffer_last_bufnr = s:INVALID_BUFNR
function! s:_type_buffer_gather(pattern)
  if s:_type_buffer_last_bufnr == bufnr('$')
    call filter(s:_type_buffer_cached_items, 'bufexists(v:val._buffer_number)')
  else
    let s:_type_buffer_cached_items = []
    let format = 'buffer %' . len(bufnr('$')) . 'd'
    for i in range(1, bufnr('$'))
      if bufexists(i) && buflisted(i)
        call add(s:_type_buffer_cached_items,
           \     {
           \       'word': bufname(i),
           \       'menu': printf(format, i),
           \       'dup': s:TRUE,
           \       '_buffer_number': i,
           \     })
      endif
    endfor
    let s:_type_buffer_last_bufnr = bufnr('$')
  endif
  return s:_type_buffer_cached_items
endfunction


function! s:_type_buffer_action_open(item)
  execute a:item._buffer_number 'buffer'.ku#bang()
endfunction
function! s:_type_buffer_action_xsplit(modifier, item)
  execute a:modifier a:item._buffer_number 'sbuffer'
endfunction
function! s:_type_buffer_action_xdelete(command, item)
  execute a:item._buffer_number a:command.ku#bang()
endfunction


call ku#register_type({
   \   'name': 'buffer',
   \   'gather': function('s:_type_buffer_gather'),
   \   'keys': {
   \     "*default*": 'open',
   \     "o": 'open',
   \     "\<C-o>": 'open',
   \     "n": 'new',
   \     "\<C-n>": 'new',
   \     "s": 'split',
   \     "\<C-s>": 'split',
   \     "v": 'vsplit',
   \     "\<C-v>": 'vsplit',
   \     "h": 'split-left',
   \     "\<C-h>": 'split-left',
   \     "H": 'split-far-left',
   \     "j": 'split-down',
   \     "\<C-j>": 'split-down',
   \     "J": 'split-bottom',
   \     "k": 'split-up',
   \     "\<C-k>": 'split-up',
   \     "K": 'split-top',
   \     "l": 'split-right',
   \     "\<C-l>": 'split-right',
   \     "L": 'split-far-right',
   \     ";": 'ex',
   \     ":": 'ex',
   \     "U": 'unload',
   \     "D": 'delete',
   \     "W": 'wipeout',
   \   },
   \   'actions': {
   \     'open':
   \       function('s:_type_buffer_action_open'),
   \     'split':
   \       s:pa('s:_type_buffer_action_xsplit', ''),
   \     'vsplit':
   \       s:pa('s:_type_buffer_action_xsplit', 'vertical'),
   \     'split-left':
   \       s:pa('s:_type_buffer_action_xsplit', 'vertical leftabove'),
   \     'split-far-left':
   \       s:pa('s:_type_buffer_action_xsplit', 'vertical topleft'),
   \     'split-down':
   \       s:pa('s:_type_buffer_action_xsplit', 'rightbelow'),
   \     'split-bottom':
   \       s:pa('s:_type_buffer_action_xsplit', 'botright'),
   \     'split-up':
   \       s:pa('s:_type_buffer_action_xsplit', 'leftabove'),
   \     'split-top':
   \       s:pa('s:_type_buffer_action_xsplit', 'topleft'),
   \     'split-right':
   \       s:pa('s:_type_buffer_action_xsplit', 'vertical rightbelow'),
   \     'split-far-right':
   \       s:pa('s:_type_buffer_action_xsplit', 'vertical botright'),
   \     'ex':
   \       function('s:_type_any_action_ex'),
   \     'unload':
   \       s:pa('s:_type_buffer_action_xdelete', 'bunload'),
   \     'delete':
   \       s:pa('s:_type_buffer_action_xdelete', 'bdelete'),
   \     'wipeout':
   \       s:pa('s:_type_buffer_action_xdelete', 'bwipeout'),
   \   },
   \ })




" file  "{{{2
" FIXME: can't list '..'.
" FIXME: unexpected propmt on some environments when glob() is called.
"        it happens when the pattern contains '{foo,bar}'.
" FIXME: smart caching.
function! s:_type_file_initialize()
  let s:_type_file_cache = {}
  let s:_type_file_frags_count = -1
endfunction

function! s:_type_file_gather(pattern)
  let c = len(split(a:pattern, '/', s:TRUE)) - 1
  if s:_type_file_frags_count != c
    let s:_type_file_frags_count = c
    let s:_type_file_cache[c]
      \ = map(split(glob(s:make_glob_pattern(a:pattern)), '\n'),
      \       "{'word': v:val, 'menu': 'file', 'dup': s:TRUE}")
  endif
  return s:_type_file_cache[c]
endfunction

function! s:make_glob_pattern(s)
  " FIXME: path separetor assumption.
  " FIXME: don't check special characters.  should they be escaped?

  " Split into components.
  let comps = split(substitute(a:s, '\s\+', '*', 'g'), '/', s:TRUE)

  " Make a pattern for each component.
  call map(comps, '"{,.[^.]}*" . v:val . "*"')
    " force searching from the root directory.
  if a:s[0] == '/'
    let comps[0] = ''
  endif

  " Remove unnecessary "*" to avoid recursively searching directories.
  call map(comps, 'substitute(v:val, "\\*\\+", "*", "g")')

  return join(comps, '/')
endfunction


" FIXME: filename with special characters -- should escape?
function! s:_type_file_action_open(item)
  execute 'edit'.ku#bang() a:item.word
endfunction
function! s:_type_file_action_xsplit(modifier, item)
  execute a:modifier 'split' a:item.word
endfunction


call ku#register_type({
   \   'name': 'file',
   \   'initialize': function('s:_type_file_initialize'),
   \   'gather': function('s:_type_file_gather'),
   \   'keys': {
   \     "*default*": 'open',
   \     "o": 'open',
   \     "\<C-o>": 'open',
   \     "n": 'new',
   \     "\<C-n>": 'new',
   \     "s": 'split',
   \     "\<C-s>": 'split',
   \     "v": 'vsplit',
   \     "\<C-v>": 'vsplit',
   \     "h": 'split-left',
   \     "\<C-h>": 'split-left',
   \     "H": 'split-far-left',
   \     "j": 'split-down',
   \     "\<C-j>": 'split-down',
   \     "J": 'split-bottom',
   \     "k": 'split-up',
   \     "\<C-k>": 'split-up',
   \     "K": 'split-top',
   \     "l": 'split-right',
   \     "\<C-l>": 'split-right',
   \     "L": 'split-far-right',
   \     ";": 'ex',
   \     ":": 'ex',
   \   },
   \   'actions': {
   \     'open':
   \       function('s:_type_file_action_open'),
   \     'split':
   \       s:pa('s:_type_file_action_xsplit', ''),
   \     'vsplit':
   \       s:pa('s:_type_file_action_xsplit', 'vertical'),
   \     'split-left':
   \       s:pa('s:_type_file_action_xsplit', 'vertical leftabove'),
   \     'split-far-left':
   \       s:pa('s:_type_file_action_xsplit', 'vertical topleft'),
   \     'split-down':
   \       s:pa('s:_type_file_action_xsplit', 'rightbelow'),
   \     'split-bottom':
   \       s:pa('s:_type_file_action_xsplit', 'botright'),
   \     'split-up':
   \       s:pa('s:_type_file_action_xsplit', 'leftabove'),
   \     'split-top':
   \       s:pa('s:_type_file_action_xsplit', 'topleft'),
   \     'split-right':
   \       s:pa('s:_type_file_action_xsplit', 'vertical rightbelow'),
   \     'split-far-right':
   \       s:pa('s:_type_file_action_xsplit', 'vertical botright'),
   \     'ex':
   \       function('s:_type_any_action_ex'),
   \   },
   \ })








" directory  "{{{2
" FIXME: not written yet -- integrate into type file?








" __END__  "{{{1
" vim: foldmethod=marker
