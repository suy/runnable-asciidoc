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
require 'asciidoctor'
require 'asciidoctor/converter'

# String helpers shared by all backends. Pure functions.
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

# The neutral document model shared by every backend.
#
# A Backend walks the Asciidoctor tree once (DocumentBuilder) and produces a
# plain hash of values; each renderer turns that hash into its output. The
# model carries no presentation: no wrapping, no blank lines, no quoting.
#
#   {
#     title:  'Document title',
#     blocks: [
#       { title: ..., hint: ..., source: [...] },  # runnable; lines array
#       ...
#     ],
#     steps: [
#       { context: [item, ...], block: block-hash or nil },
#       ...
#     ]
#   }
#
# A step is the slice of the document shown before one runnable block: its
# context items, and the block itself. The tail step (after the last block)
# has no block and is always shown at the end.
#
# Context items are values, tagged by kind:
#   { kind: :heading, text: }   section titles, rendered unconditionally
#   { kind: :title,   text: }   the title of a code block (orientation)
#   { kind: :prose,   text: }   wrapped prose (hidden by --no-prose)
#   { kind: :code,    text:, note: }  illustrative code, shown indented
module RunnableAsciidoc
  # Languages whose source blocks become runnable functions.
  RUNNABLE_LANGUAGES = %w[sh bash zsh shell].freeze

  # Terminal width used when wrapping prose.
  PROSE_WIDTH = 78
end

# The tree walk shared by all backends: converts an Asciidoctor document into
# the neutral model described above. One instance converts one document; the
# converter methods append context items, and a runnable block closes the
# pending items into a step.
class DocumentBuilder
  def initialize
    @title = nil
    @blocks = []  # runnable blocks: { title:, hint:, source: (lines array) }
    @steps = []   # { context:, block: }
    @context = [] # context items of the step being built
  end

  attr_reader :title, :blocks, :steps

  def build(node)
    @title = (node.doctitle || node.attr('docname') || 'Untitled document').to_s
    walk node.blocks
    close_step nil
    {
      title: @title,
      blocks: @blocks,
      steps: @steps
    }
  end

  # ---- block transforms ------------------------------------------------------
  #
  # Transforms append to the context and return nil; build() assembles the
  # model. Compound nodes are walked explicitly rather than through
  # node.content, so children are converted exactly once, in order.

  def convert_preamble(node)
    walk node.blocks
    nil
  end

  def convert_section(node)
    emit_heading node.level, node.title
    walk node.blocks
    nil
  end

  def convert_floating_title(node)
    emit_heading node.level, node.title
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

    if language.nil? || language.empty?
      # Unlabeled listing: illustration only, never run.
      emit_code node.source, note: nil
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
    emit_code node.source, note: nil
    nil
  end

  def convert_pass(node)
    emit_code node.content, note: nil
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

  def walk(blocks)
    blocks.each { |block| convert block }
  end

  # Asciidoctor dispatches on the node name (convert_paragraph and so on).
  # Transforms without a handler render as nothing — a terminal cannot
  # usefully show audio, video, or a table of contents.
  def convert(node, transform = node.node_name)
    handler = :"convert_#{transform}"
    return send(handler, node) if respond_to? handler, true
    ''
  end

  # ---- context items -----------------------------------------------------------

  # A heading is not prose: it orients the reader even with --no-prose, so
  # it prints unconditionally. The level is the AsciiDoc level (document
  # title is 0); renderers decide how to present it.
  def emit_heading(level, text)
    @context << { kind: :heading, level: level, text: text }
    nil
  end

  # The title of a code block. Like headings, it is not prose: it labels the
  # code, and labels must survive --no-prose or the reader gets lost.
  def emit_title(title)
    @context << { kind: :title, text: title }
    nil
  end

  def emit_prose(text)
    @context << { kind: :prose, text: text }
    nil
  end

  def emit_indented(text, prefix: '')
    @context << { kind: :prose, text: text, prefix: prefix }
    nil
  end

  # Illustrative code, printed as part of the context, optionally annotated.
  # Code is content, not prose: it prints in every mode.
  def emit_code(source, note:)
    @context << { kind: :code, text: source, note: note }
    nil
  end

  # ---- runnable blocks -------------------------------------------------------

  def runnable_language?(language)
    RunnableAsciidoc::RUNNABLE_LANGUAGES.include? language.downcase
  end

  # Records the block and closes the pending context into a step for it.
  def register_runnable_block(node)
    lines = node.source.each_line.map(&:chomp)
    # The hint shown by --list prefers the title: it is the author's
    # description of the block. The banner before a block shows the title
    # alone, so the fallback first line matters only for untitled blocks
    # in --list.
    hint = node.title || lines.first.to_s
    block = { title: node.title, hint: hint, source: lines }

    # The banner shows the title of a titled block; the same line in the
    # context would print it twice in a row.
    @context.pop if node.title && title_item?(@context.last, node.title)
    close_step block
    @blocks << block
    nil
  end

  def title_item?(item, title)
    item.is_a?(Hash) && item[:kind] == :title && item[:text] == title
  end

  def close_step(block)
    @steps << { context: @context, block: block }
    @context = []
  end
end

# Asciidoctor backend "runnable": turns a document into an interactive shell
# script. The walk produces the neutral model (DocumentBuilder); this class
# is only presentation: wrapping, blank-line collapsing, quoting, and the
# driver.
class RunnableConverter
  include Asciidoctor::Converter
  register_for 'runnable'

  # Width of the horizontal rule framing a block offer.
  RULE_WIDTH = 60

  def initialize(backend, opts = {})
    super
    outfilesuffix '.sh'
  end

  # Dispatch by transform name. The document itself assembles the script;
  # inline transforms are handled here because node.content applies inline
  # substitutions through the document's converter (this instance). The
  # block-level transforms live in DocumentBuilder, shared with the JSON
  # backend.
  def convert(node, transform = node.node_name, _opts = nil)
    return build_script(node) if %w[document embedded].include? transform
    handler = :"convert_#{transform}"
    return send(handler, node) if respond_to? handler, true
    ''
  end

  # ---- inline transforms -----------------------------------------------------
  #
  # node.content applies inline substitutions through the document's
  # converter, so these handlers must exist here as well as in
  # DocumentBuilder (which holds the authoritative copies for the model).

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

  # ---- walk, then assemble ---------------------------------------------------

  def build_script(node)
    model = DocumentBuilder.new.build node
    assemble model, node.attr('docfile')
  end

  # ---- assembly ---------------------------------------------------------------

  def assemble(model, docfile = nil)
    @index = 0
    script = +''
    script << preamble(model[:title], docfile)
    script << color_constants
    model[:steps].each_with_index do |step, index|
      # Numbering is a contract with the driver (context N introduces block
      # N), so every step gets a function. An empty body would not parse;
      # the no-op command ':' stands in for it.
      script << "runnable_context_#{format('%02d', index + 1)}() {\n"
      context_lines(step[:context]).each do |line|
        script << "  #{line}\n"
      end
      script << "  :\n" if step[:context].empty?
      script << "}\n\n"
    end
    model[:blocks].each do |block|
      script << block_definition(block) << "\n"
    end
    script << block_metadata_functions(model[:blocks])
    script << driver(model[:blocks], model[:title])
    script
  end

  # Renders one step's context items into print-call lines. The blank-line
  # scheme is presentation: separation is supplied by the items themselves
  # (a heading and a code block carry blanks, prose carries a trailing one,
  # a title carries a leading one), and runs of blank lines collapse into
  # one, as in the terminal text this output imitates.
  def context_lines(items)
    lines = [] # print-call lines of the step
    emit = ->(line) do
      lines << line unless blank_call?(line) && blank_call?(lines.last.to_s)
    end

    items.each do |item|
      case item[:kind]
      when :heading
        emit.call print_call('')
        emit.call print_call("#{'=' * (item[:level] + 1)} #{item[:text]}")
      when :title
        emit.call print_call('')
        emit.call print_call(item[:text])
      when :prose
        prefix = item[:prefix] || ''
        RunnableAsciidoc.wrap_text(item[:text], RunnableAsciidoc::PROSE_WIDTH - prefix.length).each do |line|
          emit.call print_prose_call(prefix + line)
        end
        emit.call print_prose_call('')
      when :code
        emit.call print_call('')
        emit.call print_call(item[:note]) if item[:note]
        item[:text].each_line do |line|
          emit.call print_call("    #{line.chomp}")
        end
        emit.call print_call('')
      end
    end
    lines
  end

  def blank_call?(line)
    line.empty? || line == print_call('') || line == print_prose_call('')
  end

  # The block's source lines as they will run: blank lines become `echo`
  # calls, so a blank in the document separates commands in the block's
  # output too (a bare blank line in a function body prints nothing).
  # Blank lines inside a heredoc body are data, not layout, and are kept.
  # The code echo uses the same conversion, so what you see is what runs.
  # The block's source lines as they will run: blank lines become `echo`
  # calls, so a blank in the document separates commands in the block's
  # output too (a bare blank line in a function body prints nothing).
  # Blank lines inside a heredoc body are data, not layout, and are kept:
  # the scan watches for a heredoc operator anywhere in a line, quoted or
  # not, and holds until the closing delimiter line. The code echo uses
  # the same conversion, so what you see is what runs.
  def runnable_lines(block)
    heredoc_pattern = %r{<<-?[[:space:]]*['"]?([A-Za-z_][A-Za-z0-9_]*)}
    terminator = nil
    block[:source].map do |line|
      if terminator
        terminator = nil if line == terminator
        line
      elsif (match = heredoc_pattern.match(line))
        terminator = match[1]
        line
      elsif line.strip.empty?
        'echo'
      else
        line
      end
    end
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

  def block_definition(block)
    definition = +"#{RunnableAsciidoc.block_function_name(@index += 1)}() {\n"
    runnable_lines(block).each do |line|
      definition << line << "\n"
    end
    definition << "}\n"
    definition
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

  def preamble(title, docfile = nil)
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

      runnable_working_directory() { # directory label for block headers, ~-abbreviated
        local directory=${PWD#"${HOME:-}"}
        if [ "$directory" != "$PWD" ]; then
          directory=~$directory
        fi
        printf '%s' "$directory"
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
  def block_metadata_functions(blocks)
    return '' if blocks.empty?
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
    blocks.each_with_index do |block, index|
      hint = RunnableAsciidoc.shell_single_quoted(block[:hint])
      lines << "          #{RunnableAsciidoc.block_function_name(index + 1)}) printf '%s\\n' #{hint} ;;\n"
    end
    lines << "        esac\n"
    lines << "      }\n\n"

    lines << <<~'SH'
      runnable_block_title() { # $1: function name; prints its title, if any
        case $1 in
    SH
    blocks.each_with_index do |block, index|
      next unless block[:title]
      title = RunnableAsciidoc.shell_single_quoted(block[:title])
      lines << "          #{RunnableAsciidoc.block_function_name(index + 1)}) printf '%s\\n' #{title} ;;\n"
    end
    lines << "        esac\n"
    lines << "      }\n\n"

    lines << <<~'SH'
      runnable_block_source() { # $1: function name; prints its code
        case $1 in
    SH
    blocks.each_with_index do |block, index|
      lines << "          #{RunnableAsciidoc.block_function_name(index + 1)})\n"
      runnable_lines(block).each do |line|
        lines << "            runnable_print_code #{RunnableAsciidoc.shell_single_quoted(line)}\n"
      end
      lines << "            ;;\n"
    end
    lines << "        esac\n"
    lines << "      }\n\n"
    lines.sub!("RUNNABLE_LIST_TOTAL", (blocks.size).to_s)
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
          runnable_print "  in $(runnable_working_directory)"
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
  def driver(blocks, title)
    total = blocks.size
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
            runnable_print "  in $(runnable_working_directory)"
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


# Asciidoctor backend "runnable-json": turns a document into a JSON document
# for a graphical (QML) viewer. Same walk, same model, different renderer.
#
# Schema (version 1):
#
#   {
#     "version": 1,
#     "title": "Document title",
#     "steps": [
#       {
#         "context": [
#           { "kind": "heading", "level": 1, "text": "First" },
#           { "kind": "title",   "text": "Build the demo" },
#           { "kind": "prose",   "text": "Before text.", "prefix": "" },
#           { "kind": "code",    "text": "echo one", "note": "(not run)" }
#         ],
#         "block": null,     // or the runnable block introduced by the step
#         // block object: { "title", "hint", "source": [line, ...] }
#       }
#     ]
#   }
#
# The viewer owns all presentation: wrapping, spacing, quoting, colors. One
# JSON field per line (pretty_generate) keeps diffs readable.
class JsonConverter
  include Asciidoctor::Converter
  register_for 'runnable-json'

  def initialize(backend, opts = {})
    super
    outfilesuffix '.json'
  end

  def convert(node, transform = node.node_name, _opts = nil)
    return build_json(node) if %w[document embedded].include? transform
    handler = :"convert_#{transform}"
    return send(handler, node) if respond_to? handler, true
    ''
  end

  # ---- inline transforms (see DocumentBuilder for the authoritative copies) --

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

  def build_json(node)
    model = DocumentBuilder.new.build node
    json = {
      'version' => 1,
      'title' => model[:title],
      'steps' => model[:steps].map { |step| step_json(step) }
    }
    JSON.pretty_generate(json) + "\n"
  end

  def step_json(step)
    {
      'context' => step[:context].map { |item| context_item_json(item) },
      'block' => step[:block] && block_json(step[:block])
    }
  end

  def context_item_json(item)
    json = { 'kind' => item[:kind].to_s, 'text' => item[:text] }
    json['level'] = item[:level] if item.key? :level
    json['note'] = item[:note] if item.key? :note
    json['prefix'] = item[:prefix] if item.key? :prefix
    json
  end

  def block_json(block)
    {
      'title' => block[:title],
      'hint' => block[:hint],
      'source' => block[:source]
    }
  end
end

require 'json'
