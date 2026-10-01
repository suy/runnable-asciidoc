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
end

class RunnableConverter
  include Asciidoctor::Converter
  register_for 'runnable'

  # Languages whose source blocks become runnable functions.
  RUNNABLE_LANGUAGES = %w[sh bash zsh shell].freeze
  # Terminal width used when wrapping prose.
  PROSE_WIDTH = 78

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
    @context_lines << '' << ''
    nil
  end

  def convert_page_break(_node)
    @context_lines << '' << ''
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
      emit_line print_call(line)
    end
    emit_blank
    nil
  end

  def emit_heading(text)
    emit_blank
    emit_line print_call(text)
    emit_blank
    nil
  end

  def emit_indented(text, prefix: '')
    RunnableAsciidoc.wrap_text(text, PROSE_WIDTH - prefix.length).each do |line|
      emit_line print_call(prefix + line)
    end
    emit_blank
    nil
  end

  # Illustrative code, printed as part of the context, optionally annotated.
  def emit_code(source, note: nil)
    emit_line print_call(note) if note
    source.each_line do |line|
      emit_line print_call("    #{line.chomp}")
    end
    emit_blank
    nil
  end

  # Appends one output line, collapsing runs of blank lines into one.
  def emit_line(line)
    @context_lines << line unless line.empty? && @context_lines.last == ''
    nil
  end

  def emit_blank
    emit_line ''
  end

  def print_call(text)
    %(runnable_print #{RunnableAsciidoc.shell_single_quoted(text)})
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
    @blocks << { function: function, first_line: node.source.each_line.first.to_s.chomp }

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
    @chunks.each_with_index do |chunk, index|
      # Numbering is a contract with the driver (context N introduces block
      # N), so every chunk gets a function. An empty body would not parse;
      # the no-op command ':' stands in for it.
      script << "runnable_context_#{format('%02d', index + 1)}() {\n"
      if chunk[:context].empty?
        script << "  :\n"
      else
        chunk[:context].each do |line|
          script << (line.empty? ? "\n" : "  #{line}\n")
        end
      end
      script << "}\n\n"
    end
    @block_definitions.each do |definition|
      script << definition << "\n"
    end
    script << list_function
    script << driver(title)
    script
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
    SH
  end

  def list_function
    return '' if @blocks.empty?
    lines = +<<~'SH'
      runnable_show_list() {
        printf '%s\n' 'Runnable blocks:'
        local index
        for ((index = 1; index <= RUNNABLE_LIST_TOTAL; index++)); do
          printf '  block_%02d: %s\n' "$index" "$(runnable_block_hint "$(printf 'block_%02d' "$index")")"
        done
      }

      runnable_block_hint() { # $1: function name; prints its first line
        case $1 in
    SH
    @blocks.each do |block|
      hint = RunnableAsciidoc.shell_single_quoted(block[:first_line])
      lines << "          #{block[:function]}) printf '%s\\n' #{hint} ;;\n"
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
            printf '  Block failed with exit status %d.\\n' "$status"
          fi
          if [ "$RUNNABLE_ASSUME_YES" -eq 1 ]; then
            [ "$status" -eq 0 ] && return 0 || return 2
          fi
          runnable_ask '  [r] re-run · [Enter] continue · [q] quit > '
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
        printf '%s\\n' "usage: $0 [--list | --yes | --reset | --help]"
      }

      main() {
        RUNNABLE_ASSUME_YES=0
        RUNNABLE_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
        case ${1:-} in
          --list) runnable_show_list; return 0 ;;
          --yes) RUNNABLE_ASSUME_YES=1 ;;
          --reset)
            rm -f "$(runnable_progress_file)"
            printf '%s\\n' 'Progress cleared.'
            return 0
            ;;
          -h|--help) usage; return 0 ;;
          '') ;;
          *) usage; return 2 ;;
        esac

        RUNNABLE_TOTAL=#{total}
        RUNNABLE_FINISHED=0

        printf '%s\\n' #{RunnableAsciidoc.shell_single_quoted("=== #{title} ===")}
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
          for ((index = 1; index <= RUNNABLE_TOTAL; index++)); do
            name=$(printf 'block_%02d' "$index")
            state=$(runnable_state "$name")
            if [ "$state" = done ] || [ "$state" = skipped ]; then
              continue
            fi
            runnable_context_$(printf '%02d' "$index")
            if [ "$RUNNABLE_ASSUME_YES" -eq 0 ]; then
              runnable_ask '  [Enter] run · [s] skip · [q] quit > '
              case $? in
                13)
                  runnable_record "$name" skipped
                  continue
                  ;;
                17)
                  printf '%s\\n' "Stopped before block $index. Run this script again to resume."
                  return 0
                  ;;
              esac
            fi
            printf '%s\\n' "--- block $index/$RUNNABLE_TOTAL: $(runnable_block_hint "$name")"
            run_block "$name"
            case $? in
              2)
                printf '%s\\n' "Stopped after block $index. Run this script again to resume."
                return 0
                ;;
            esac
            runnable_show_progress
          done

          runnable_context_#{format('%02d', total + 1)}
          local failures
          failures=$(awk '$2 == "failed" { count++ } END { print count + 0 }' "$(runnable_progress_file)")
          if [ "$failures" -gt 0 ]; then
            printf '%s\\n' "$failures block(s) failed; they will be offered again next run."
          else
            printf '%s\\n' 'All blocks handled.'
          fi
        }

        main "$@"
    SH
    parts
  end
end
