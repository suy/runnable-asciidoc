# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Alejandro Exojo Piqueras
#
# runnable-asciidoc — an Asciidoctor backend that converts a document into an
# interactive shell script. Prose becomes terminal output, shell code blocks
# become shell functions, and a driver runs them one at a time with a
# checkpoint between blocks: continue, skip, re-run, or quit. Progress is
# saved and resumable: already-run blocks (and their prose) are not shown.
#
# Usage (adjust GEM_HOME to wherever the asciidoctor gem lives):
#
#   GEM_HOME=$HOME/local/gems asciidoctor -r ./lib/runnable-asciidoc \
#     -b runnable -o setup.sh doc.adoc
#
# The generated script understands:
#   (no flags)  interactive: stop after each block
#   --list      show the runnable blocks and exit, running nothing
#   --yes       run all pending blocks, stop at the first failure
#   --no-prose  hide the prose; keep headings, titles, and code
#   --color     force colors on (default: on for a terminal, off for a pipe)
#   --no-color  force colors off
#   --reset     discard saved progress
#   --help      show usage

require 'asciidoctor'
require 'asciidoctor/converter'

# String helpers used to emit shell code. Pure functions.
module RunnableAsciidoc
  module_function

  # A single-quoted shell literal. The only special character is the single
  # quote itself, which cannot be escaped inside single quotes; the standard
  # workaround closes the quote, inserts an escaped quote, and reopens.
  def shell_single_quoted(text)
    "'#{text.to_s.gsub("'") { "'\\''" }}'"
  end

  # A shell function name for a runnable block, zero-padded so textual order
  # matches numeric order even with more than nine blocks.
  def block_function_name(index)
    format('block_%02d', index)
  end

  # Greedy word wrap that preserves explicit newlines. Returns an array of
  # lines, each within width when possible; a single long word is kept intact.
  def wrap_text(text, width)
    text.to_s.split("\n").flat_map do |line|
      next [''] if line.empty?
      chunks = []
      current = +''
      line.split(' ').each do |word|
        candidate = current.empty? ? word : %(#{current} #{word})
        if candidate.length <= width || current.empty?
          current = candidate
        else
          chunks << current
          current = word
        end
      end
      chunks << current unless current.empty?
      chunks
    end
  end

  # ANSI escape sequences for the generated script's output. Emitted as
  # generation-time constants and printed only through runtime functions
  # that check tty-ness (RUNNABLE_COLOR_ENABLED is set once, in main), so
  # redirects and pipes stay clean.
  COLORS = {
    bold: '1',
    yellow: '33',
    red: '31'
  }.freeze

  COLORS.each do |name, code|
    define_method("color_#{name}") { format("\e[%sm", code) }
    module_function "color_#{name}"
  end

  def color_reset
    "\e[0m"
  end
  module_function :color_reset
end

class RunnableConverter
  include Asciidoctor::Converter
  register_for 'runnable'

  # Languages whose source blocks become runnable functions.
  RUNNABLE_LANGUAGES = %w[sh bash zsh shell].freeze
  # Terminal width used when wrapping prose.
  PROSE_WIDTH = 78
  # Width of the horizontal rule framing a block offer.
  RULE_WIDTH = 60

  def initialize(backend, opts = {})
    super
    outfilesuffix '.sh'
    # The document is cut into chunks at every runnable block: the terminal
    # text accumulated so far becomes the context shown before that block.
    @context_lines = []     # terminal text of the chunk being built
    @chunks = []            # { context: Array, block: function-name or nil }
    @block_definitions = [] # script source of each runnable block function
    @blocks = []            # { function:, first_line: }
  end

  # Dispatch by transform name (the node name): convert_paragraph,
  # convert_inline_quoted, and so on. Transforms without a handler render as
  # nothing — a script cannot usefully show audio, video, or a table of
  # contents.
  def convert(node, transform = node.node_name, _opts = nil)
    handler = :"convert_#{transform}"
    return send(handler, node) if respond_to? handler, true
    ''
  end

  # ---- block transforms ------------------------------------------------------
  #
  # Transforms append to the streams and return nil; the document transform
  # assembles the script. Compound nodes are walked explicitly rather than
  # through node.content, so children are converted exactly once, in order.

  def convert_document(node)
    @context_lines.clear
    @chunks.clear
    @block_definitions.clear
    @blocks.clear
    walk node.blocks
    close_chunk
    assemble node
  end

  # Programmatic use (Asciidoctor.load followed by Document#convert) defaults
  # to the "embedded" transform; the script is the same either way.
  alias convert_embedded convert_document

  def convert_preamble(node)
    walk node.blocks
    nil
  end

  def convert_section(node)
    emit_heading "#{'=' * (node.level + 1)} #{node.title}"
    walk node.blocks
    nil
  end

  def convert_floating_title(node)
    emit_heading "#{'=' * (node.level + 1)} #{node.title}"
    nil
  end

  def convert_paragraph(node)
    emit_prose node.content
    nil
  end

  def convert_admonition(node)
    if node.content_model == :simple
      emit_prose "#{node.style.upcase}: #{node.content}"
    else
      emit_prose "#{node.style.upcase}:"
      walk node.blocks
    end
    nil
  end

  def convert_quote(node)
    walk node.blocks
    attribution = node.attr 'attribution'
    emit_prose "— #{attribution}" if attribution
    nil
  end

  def convert_sidebar(node)
    walk node.blocks
    nil
  end

  def convert_example(node)
    walk node.blocks
    nil
  end

  def convert_open(node)
    walk node.blocks
    nil
  end

  def convert_ulist(node)
    node.items.each do |item|
      emit_prose "- #{item.text}"
      walk item.blocks
    end
    nil
  end

  def convert_olist(node)
    node.items.each_with_index do |item, index|
      emit_prose "#{index + 1}. #{item.text}"
      walk item.blocks
    end
    nil
  end

  def convert_dlist(node)
    node.items.each do |terms, description|
      terms.each { |term| emit_prose term.text }
      next unless description
      emit_indented description.text, prefix: '    ' if description.text?
      walk description.blocks
    end
    nil
  end

  def convert_colist(node)
    node.items.each_with_index do |item, index|
      emit_prose "  <#{index + 1}> #{item.text}"
    end
    nil
  end

  def convert_listing(node)
    language = node.attr 'language'
    emit_title node.title if node.title

    if language.nil? || language.empty?
      # Unlabeled listing: illustration only, never run.
      emit_code node.source
      return nil
    end

    if node.attr? 'norun-option'
      # opts=norun in the block attributes: asciidoctor turns it into the
      # "norun-option" attribute.
      emit_code node.source, note: '(not run)'
      return nil
    end

    unless runnable_language? language
      emit_code node.source, note: "(#{language}, not run)"
      return nil
    end

    register_runnable_block node
    nil
  end

  def convert_literal(node)
    emit_code node.source
    nil
  end

  def convert_pass(node)
    emit_code node.content
    nil
  end

  # ---- placeholders: the real content lives in the document ------------------

  def convert_table(_node)
    emit_prose '[table omitted — see the document]'
    nil
  end

  def convert_image(_node)
    emit_prose '[image omitted — see the document]'
    nil
  end

  def convert_stem(_node)
    emit_prose '[formula omitted — see the document]'
    nil
  end

  def convert_thematic_break(_node)
    emit_blank
    nil
  end

  def convert_page_break(_node)
    emit_blank
    nil
  end

  # ---- inline transforms: prose that reads well in a terminal ----------------

  def convert_inline_quoted(node)
    node.text
  end

  def convert_inline_anchor(node)
    case node.type
    when :link
      text = node.text
      url = node.target
      text.empty? || text == url ? url : %(#{text} (#{url}))
    when :xref
      node.text.to_s.empty? ? node.target.to_s : node.text
    else
      node.text.to_s
    end
  end

  def convert_inline_footnote(node)
    node.type == :ref ? '' : %( [note: #{node.text}])
  end

  def convert_inline_break(node)
    %(#{node.text}\n)
  end

  def convert_inline_callout(node)
    %(<#{node.text}>)
  end

  def convert_inline_kbd(node)
    node.attr 'keys'
  end

  def convert_inline_menu(node)
    [node.attr('menu'), *node.attr('menuitems').to_s.split].compact.join(' > ')
  end

  def convert_inline_image(node)
    alt = node.attr 'alt'
    alt.to_s.empty? ? '[image]' : "[image: #{alt}]"
  end

  def convert_inline_indexterm(_node)
    ''
  end

  private

  # ---- tree walking ----------------------------------------------------------

  def walk(blocks)
    blocks.each { |block| convert block }
  end

  # ---- chunks ------------------------------------------------------------------
  #
  # A chunk is the slice of the document shown before one runnable block:
  # its prose, and the block itself. The tail chunk (after the last block)
  # has no block and is always shown at the end.

  def close_chunk
    @chunks << { context: @context_lines, block: nil }
    @context_lines = []
  end

  # ---- stream emitters -------------------------------------------------------

  def emit_prose(text)
    RunnableAsciidoc.wrap_text(text, PROSE_WIDTH).each do |line|
      emit_line print_prose_call(line)
    end
    emit_blank_prose
    nil
  end

  # A heading is not prose: it orients the reader even with --no-prose, so
  # it prints unconditionally. The blank line that separated a heading from
  # what follows belonged to the heading; separation is now supplied by the
  # follower itself (a paragraph's trailing blank, code's leading blank),
  # which keeps single spacing in both modes.
  def emit_heading(text)
    emit_blank
    emit_line print_call(text)
    nil
  end

  # The title of a code block. Like headings, it is not prose: it labels the
  # code, and labels must survive --no-prose or the reader gets lost.
  def emit_title(title)
    emit_blank
    emit_line print_call(title)
    nil
  end

  def emit_indented(text, prefix: '')
    RunnableAsciidoc.wrap_text(text, PROSE_WIDTH - prefix.length).each do |line|
      emit_line print_prose_call(prefix + line)
    end
    emit_blank_prose
    nil
  end

  # Illustrative code, printed as part of the context, optionally annotated.
  # Code is content, not prose: it prints in every mode.
  def emit_code(source, note: nil)
    emit_blank
    emit_line print_call(note) if note
    source.each_line do |line|
      emit_line print_call("    #{line.chomp}")
    end
    emit_blank
    nil
  end

  # Appends one output line, collapsing runs of blank lines into one.
  # A blank is a printed empty line (either kind of print call) or, for the
  # very start of a chunk, a pending empty string.
  def emit_line(line)
    @context_lines << line unless blank_call?(line) && blank_call?(@context_lines.last.to_s)
    nil
  end

  def blank_call?(line)
    line.empty? || line == print_call('') || line == print_prose_call('')
  end

  # A structural blank: separation around headings, titles, and code. It is
  # content-independent, so it prints in every mode.
  def emit_blank
    emit_line print_call('')
  end

  def print_call(text)
    %(runnable_print #{RunnableAsciidoc.shell_single_quoted(text)})
  end

  # Prose lines go through a runtime gate so that --no-prose can hide the
  # explanation while keeping everything that orients: headings, titles, and
  # code. A paragraph's trailing blank is gated together with it.
  def print_prose_call(text)
    %(runnable_print_prose #{RunnableAsciidoc.shell_single_quoted(text)})
  end

  def emit_blank_prose
    emit_line print_prose_call('')
  end

  # ---- runnable blocks -------------------------------------------------------

  def runnable_language?(language)
    RUNNABLE_LANGUAGES.include? language.downcase
  end

  # Records the block, closes the pending context into a chunk for it, and
  # emits its function definition. The body is emitted at column zero and
  # verbatim, so anything the block contains (heredocs included) runs exactly
  # as written in the document.
  def register_runnable_block(node)
    index = @blocks.size + 1
    function = RunnableAsciidoc.block_function_name index
    first_line = node.source.each_line.first.to_s.chomp
    # The hint shown by --list prefers the title: it is the author's
    # description of the block. The banner before a block shows the title
    # alone (runnable_block_title), so the fallback first line matters
    # only for untitled blocks in --list.
    hint = node.title || first_line
    @blocks << { function: function, first_line: first_line, hint: hint,
                 title: node.title, source: node.source }

    # The banner shows the title of a titled block; the same line in the
    # context would print it twice in a row.
    @context_lines.pop if node.title && @context_lines.last == print_call(node.title)
    @chunks << { context: @context_lines, block: function }
    @context_lines = []

    definition = +"#{function}() {\n"
    node.source.each_line do |line|
      definition << line
      definition << "\n" unless line.end_with?("\n")
    end
    definition << "}\n"
    @block_definitions << definition
    nil
  end

  # ---- assembly ---------------------------------------------------------------

  def assemble(node)
    title = (node.doctitle || node.attr('docname') || 'Untitled document').to_s
    docfile = node.attr 'docfile'

    script = +''
    script << preamble(title, docfile)
    script << color_constants
    @chunks.each_with_index do |chunk, index|
      # Numbering is a contract with the driver (context N introduces block
      # N), so every chunk gets a function. An empty body would not parse;
      # the no-op command ':' stands in for it.
      script << "runnable_context_#{format('%02d', index + 1)}() {\n"
      if chunk[:context].empty?
        script << "  :\n"
      else
        chunk[:context].each do |line|
          script << "  #{line}\n"
        end
      end
      script << "}\n\n"
    end
    @block_definitions.each do |definition|
      script << definition << "\n"
    end
    script << block_metadata_functions
    script << driver(title)
    script
  end

  # Generation-time ANSI constants, one per color the runtime functions use.
  # The runtime functions are the only users, so adding a new color means
  # adding it here and to RunnableAsciidoc::COLORS.
  def color_constants
    lines = +"\n"
    {
      'BOLD' => RunnableAsciidoc.color_bold,
      'YELLOW' => RunnableAsciidoc.color_yellow,
      'RED' => RunnableAsciidoc.color_red,
      'RESET' => RunnableAsciidoc.color_reset
    }.each do |suffix, sequence|
      lines << "RUNNABLE_COLOR_#{suffix}=$'\\e[#{sequence_code(sequence)}m'\n"
    end
    lines
  end

  # The SGR parameter of an escape sequence built by the color_* helpers.
  def sequence_code(sequence)
    sequence[/\e\[(\d+)m/, 1]
  end

  def preamble(title, docfile)
    <<~SH
      #!/usr/bin/env bash
      #
      # #{title}
      # Generated by runnable-asciidoc from: #{docfile || '(standard input)'}
      # This file is generated. Edit the .adoc document and regenerate it.
      #
      set -u

      runnable_print() {
        printf '%s\\n' "$1"
      }

      runnable_print_prose() { # $1: line; hidden by --no-prose
        [ "$RUNNABLE_SHOW_PROSE" -eq 0 ] && return 0
        printf '%s\\n' "$1"
      }

      runnable_print_code() { # $1: line of code being echoed
        printf '    %s\\n' "$1"
      }

      runnable_rule() { # fixed-width horizontal rule framing a block offer
        printf '%s\n' '╋#{"━" * RULE_WIDTH}'
      }

      runnable_ask() { # $1: prompt; returns 0 enter, 13 skip, 14 re-run, 17 quit
        local reply
        printf '%s' "$1"
        read -r reply
        case $reply in
          s) return 13 ;;
          r) return 14 ;;
          q) return 17 ;;
          *) return 0 ;;
        esac
      }

      runnable_progress_file() {
        printf '%s/%s.progress' "$RUNNABLE_SELF_DIR" "$(basename -- "$0")"
      }

      runnable_record() { # $1: function name, $2: state (done, skipped, failed)
        local file
        file=$(runnable_progress_file)
        if [ -f "$file" ]; then
          grep -v "^$1 " "$file" > "$file.tmp" || true
        fi
        {
          [ -f "$file.tmp" ] && cat "$file.tmp"
          printf '%s %s\\n' "$1" "$2"
        } > "$file"
        rm -f "$file.tmp"
      }

      runnable_state() { # $1: function name; prints the recorded state, if any
        local file
        file=$(runnable_progress_file)
        if [ -f "$file" ]; then
          awk -v block="$1" '$1 == block { print $2; exit }' "$file"
        fi
      }

      runnable_show_progress() {
        printf '  %d/%d finished\\n' "$RUNNABLE_FINISHED" "$RUNNABLE_TOTAL"
      }

      # ---- color -------------------------------------------------------------

      # True when colors should be enabled: stdout is a terminal, TERM is
      # set, and TERM is not 'dumb'. Checked once in main; when false, all
      # color functions below print empty strings and output is plain text.
      runnable_use_color() {
        [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ]
      }

      runnable_color_reset() { # $RUNNABLE_COLOR_ENABLED: 1 to emit the code
        [ "$RUNNABLE_COLOR_ENABLED" -eq 1 ] && printf '\e[0m'
      }

      runnable_color_bold() {
        [ "$RUNNABLE_COLOR_ENABLED" -eq 1 ] && printf '\e[1m'
      }

      runnable_color_yellow() {
        [ "$RUNNABLE_COLOR_ENABLED" -eq 1 ] && printf '\e[33m'
      }

      runnable_color_red() {
        [ "$RUNNABLE_COLOR_ENABLED" -eq 1 ] && printf '\e[31m'
      }

      # A runtime-checked colored string (plain when colors are off).
      # Applies RUNNABLE_COLOR_CHOICE: 2 = auto (tty detection), 1 = on,
      # 0 = off. Called from the --list branch and after flag parsing.
      runnable_apply_color_choice() {
        RUNNABLE_COLOR_ENABLED=0
        if [ "$RUNNABLE_COLOR_CHOICE" -eq 2 ]; then
          runnable_use_color && RUNNABLE_COLOR_ENABLED=1
        else
          RUNNABLE_COLOR_ENABLED=$RUNNABLE_COLOR_CHOICE
        fi
      }

      runnable_paint() { # $1: color function name, $2: text
        local color_reset
        color_reset=$(runnable_color_reset)
        printf '%s%s%s' "$("$1")" "$2" "$color_reset"
      }
    SH
  end

  # Functions that carry per-block metadata into the generated script: the
  # --list view (one line per block) and the verbatim source echoed before
  # a block runs.
  def block_metadata_functions
    return '' if @blocks.empty?
    lines = +<<~'SH'
      runnable_show_list() {
        printf '%s\n' "$(runnable_paint runnable_color_bold 'Runnable blocks:')"
        local index
        for ((index = 1; index <= RUNNABLE_LIST_TOTAL; index++)); do
          printf '  %s %s\n' \
            "$(runnable_paint runnable_color_bold "$(printf 'block_%02d:' "$index")")" \
            "$(runnable_block_hint "$(printf 'block_%02d' "$index")")"
        done
      }

      runnable_block_hint() { # $1: function name; prints its first line
        case $1 in
    SH
    @blocks.each do |block|
      hint = RunnableAsciidoc.shell_single_quoted(block[:hint])
      lines << "          #{block[:function]}) printf '%s\\n' #{hint} ;;\n"
    end
    lines << "        esac\n"
    lines << "      }\n\n"

    lines << <<~'SH'
      runnable_block_title() { # $1: function name; prints its title, if any
        case $1 in
    SH
    @blocks.each do |block|
      next unless block[:title]
      title = RunnableAsciidoc.shell_single_quoted(block[:title])
      lines << "          #{block[:function]}) printf '%s\\n' #{title} ;;\n"
    end
    lines << "        esac\n"
    lines << "      }\n\n"

    lines << <<~'SH'
      runnable_block_source() { # $1: function name; prints its code
        case $1 in
    SH
    @blocks.each do |block|
      lines << "          #{block[:function]})\n"
      block[:source].each_line do |line|
        lines << "            runnable_print_code #{RunnableAsciidoc.shell_single_quoted(line.chomp)}\n"
      end
      lines << "            ;;\n"
    end
    lines << "        esac\n"
    lines << "      }\n\n"
    lines.sub!("RUNNABLE_LIST_TOTAL", (@blocks.size).to_s)
    lines
  end

  def run_block_function
    <<~SH
      run_block() { # $1: function name; returns 0 finished/skipped, 2 stop
        local name=$1
        while true; do
          "$name"
          local status=$?
          if [ "$status" -eq 0 ]; then
            runnable_record "$name" done
            RUNNABLE_FINISHED=$((RUNNABLE_FINISHED + 1))
          else
            runnable_record "$name" failed
            printf '%s\\n' "$(runnable_paint runnable_color_red "  Block failed with exit status $status.")"
          fi
          if [ "$RUNNABLE_ASSUME_YES" -eq 1 ]; then
            [ "$status" -eq 0 ] && return 0 || return 2
          fi
          printf '\\n'
          runnable_ask '  '"$(runnable_paint runnable_color_bold '[r] re-run · [Enter] continue · [q] quit > ')"
          case $? in
            14) continue ;;
            17) return 2 ;;
          esac
          return 0
        done
      }
    SH
  end

  def driver(title)
    total = @blocks.size
    parts = +''
    parts << run_block_function
    parts << <<~SH

      usage() {
        printf '%s\\n' "usage: $0 [--list | --yes | --no-prose | --color | --no-color | --reset | --help]"
      }

      main() {
        RUNNABLE_ASSUME_YES=0
        RUNNABLE_SHOW_PROSE=1
        # Set before flag parsing: --list returns from inside the loop,
        # and the paint functions must never see an unbound variable.
        RUNNABLE_COLOR_ENABLED=0
        RUNNABLE_COLOR_CHOICE=2
        RUNNABLE_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
        while [ "$#" -gt 0 ]; do
          case $1 in
            --list)
              runnable_apply_color_choice
              runnable_show_list
              return 0
              ;;
            --yes) RUNNABLE_ASSUME_YES=1 ;;
            --no-prose) RUNNABLE_SHOW_PROSE=0 ;;
            --color) RUNNABLE_COLOR_CHOICE=1 ;;
            --no-color) RUNNABLE_COLOR_CHOICE=0 ;;
            --reset)
              rm -f "$(runnable_progress_file)"
              printf '%s\\n' 'Progress cleared.'
              return 0
              ;;
            -h|--help) usage; return 0 ;;
            *) usage; return 2 ;;
          esac
          shift
        done

        runnable_apply_color_choice

        RUNNABLE_TOTAL=#{total}
        RUNNABLE_FINISHED=0

        printf '%s\\n' "$(runnable_paint runnable_color_bold #{RunnableAsciidoc.shell_single_quoted("=== #{title} ===")})"
    SH

    if total.zero?
      parts << "        runnable_context_01\n"
      parts << "        printf '%s\\n' 'This document has no runnable blocks.'\n"
      parts << "        return 0\n      }\n\nmain \"$@\"\n"
      return parts
    end

    parts << <<~SH

          local index
          local name
          local state
          local failures
          for ((index = 1; index <= RUNNABLE_TOTAL; index++)); do
            name=$(printf 'block_%02d' "$index")
            state=$(runnable_state "$name")
            if [ "$state" = done ] || [ "$state" = skipped ]; then
              continue
            fi
            runnable_context_$(printf '%02d' "$index")
            runnable_rule
            local block_title
            block_title=$(runnable_block_title "$name")
            printf '%s\\n' "$(runnable_paint runnable_color_bold "┃ block $index/$RUNNABLE_TOTAL:") $block_title"
            runnable_rule
            runnable_block_source "$name"
            runnable_rule
            if [ "$RUNNABLE_ASSUME_YES" -eq 0 ]; then
              runnable_ask '  '"$(runnable_paint runnable_color_bold '[Enter] run · [s] skip · [q] quit > ')"
              case $? in
                13)
                  runnable_record "$name" skipped
                  continue
                  ;;
                17)
                  printf '%s\\n' "$(runnable_paint runnable_color_yellow "Stopped before block $index. Run this script again to resume.")"
                  return 0
                  ;;
              esac
            fi
            run_block "$name"
            case $? in
              2)
                printf '%s\\n' "$(runnable_paint runnable_color_yellow "Stopped after block $index. Run this script again to resume.")"
                return 0
                ;;
            esac
            runnable_show_progress
            printf '\\n'
          done

          runnable_context_#{format('%02d', total + 1)}
          failures=$(awk '$2 == "failed" { count++ } END { print count + 0 }' "$(runnable_progress_file)")
          if [ "$failures" -gt 0 ]; then
            printf '%s\\n' "$(runnable_paint runnable_color_red "$failures block(s) failed; they will be offered again next run.")"
          else
            printf '%s\\n' 'All blocks handled.'
          fi
        }

        main "$@"
    SH
    parts
  end
end
