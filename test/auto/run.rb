# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Alejandro Exojo Piqueras
#
# End-to-end tests for the runnable-asciidoc backend: convert example
# documents, syntax-check the generated scripts, and drive them.
#
# Run with: ruby test/auto/run.rb (minitest ships with Ruby; no gems needed)

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'pty'
require 'expect'

PROJECT = File.expand_path('../..', __dir__)
LIB = File.join(PROJECT, 'lib', 'runnable-asciidoc.rb')

require 'asciidoctor' unless defined?(Asciidoctor)
require LIB

# Converts an AsciiDoc string through the runnable backend. Returns the
# generated script path; the sandbox directory stays in @dir and is
# removed when the test process exits.
def convert(adoc, name = 'doc.adoc', backend: 'runnable')
  @dir = Dir.mktmpdir
  Minitest.after_run { FileUtils.remove_entry(@dir) if File.exist?(@dir) }
  source = File.join(@dir, name)
  File.write(source, adoc)
  suffix = backend == 'runnable' ? 'sh' : 'json'
  output = File.join(@dir, "#{File.basename(name, '.adoc')}.#{suffix}")
  _out, error, status = Open3.capture3(
    { 'GEM_HOME' => ENV['GEM_HOME'] }.compact,
    'ruby', '-I', File.dirname(LIB), '-rasciidoctor',
    '-r', LIB, '-e',
    "Asciidoctor.convert_file #{source.inspect}, " \
    "backend: #{backend.inspect}, safe: :unsafe, to_file: #{output.inspect}, mkdirs: true"
  )
  flunk "conversion failed:\n#{error}" unless status.success?
  output
end

# Runs the generated script with the given stdin, returns [stdout, status].
def run_script(script, stdin: '', args: [])
  out, status = Open3.capture2e({ 'HOME' => Dir.tmpdir }, 'bash', script, *args, stdin_data: stdin)
  [out, status]
end

# Runs the generated script on a pseudo-terminal, so the script sees a tty
# stdout and a tty stdin — the real usage. The answers are written to the
# pty up front; the tty line discipline queues them, and the script's
# blocking reads consume them one line at a time. Returns [output, status].
module PtyRun
  module_function

  def run(script, args: [], answers: [])
    output = +''
    status = nil
    PTY.spawn({ 'HOME' => Dir.tmpdir, 'TERM' => 'xterm-256color' },
              'bash', script, *args) do |read, write, pid|
      write.sync = true
      # The tty line discipline queues the answers; the script's blocking
      # reads consume them one line at a time. The write side stays open
      # while reading: closing it early tears down the pty before the
      # child's output can be read. Callers must queue enough answers for
      # the script to reach one of its exits.
      answers.each { |answer| write.puts(answer) }
      begin
        while (chunk = read.readpartial(4096))
          output << chunk
        end
      rescue EOFError, Errno::EIO
        # child exited: pty reads end with EOFError or EIO
      end
      Process.wait(pid)
      status = $?
      write.close
    end
    output.force_encoding(Encoding::UTF_8)
    [output, status]
  end
end
  SAMPLE_TWO_BLOCK = <<~ADOC
    = Two

    [source,bash]
    ----
    echo things
    echo more
    ----
  ADOC

SAMPLE = <<~ADOC
  = Sample
  :project: xyz

  Intro prose with *bold*, `code`, and a link:https://example.org[site].

  == First

  Before text.

  [source,bash]
  ----
  echo one
  ----

  == Second

  [source,bash,opts=norun]
  ----
  echo not-run
  ----

  [source,python]
  ----
  print("py")
  ----

  ----
  unlabeled
  ----

  [source,bash]
  .Do things
  ----
  echo two
  ----

  Closing prose.
ADOC

class ConversionTest < Minitest::Test

  def setup
    @script = convert SAMPLE
  end

  def test_generated_script_is_valid_bash
    _out, status = Open3.capture2e('bash', '-n', @script)
    assert status.success?
  end

  def test_two_runnable_blocks
    out, _status = run_script @script, args: ['--list']
    assert_includes out, 'block_01: echo one'
    assert_includes out, 'block_02: Do things'
    refute_includes out, 'not-run'
  end

  def test_norun_and_foreign_blocks_are_context_only
    File.write(@script, File.read(@script)) # no-op, keep path stable
    content = File.read(@script)
    assert_includes content, 'echo not-run'
    assert_includes content, '(python, not run)'
    assert_includes content, 'unlabeled'
    refute_includes content, 'block_03()'
  end

  def test_prose_markup_expanded
    content = File.read(@script)
    assert_includes content, 'Intro prose with bold, code, and a site (https://example.org).'
  end

  def test_paragraph_breaks_print_blank_lines
    out, _status = run_script @script, args: ['--yes']
    assert_includes out, "Intro prose with bold, code, and a site (https://example.org).\n\n"
  end

  def test_no_prose_hides_prose_but_keeps_headings_and_code
    out, status = run_script @script, args: ['--yes', '--no-prose']
    assert status.success?
    refute_includes out, 'Before text.'
    refute_includes out, 'Closing prose.'
    assert_includes out, '=== Sample ==='
    assert_includes out, '== First'
    assert_includes out, '== Second'
    assert_includes out, 'echo one'
    assert_includes out, 'echo two'
    assert_includes out, '(python, not run)'
  end

  def test_no_prose_flag_combines_and_rejects_unknown_flags
    _out, status = run_script @script, args: ['--no-prose', '--yes']
    assert status.success?
    _out, status = run_script @script, args: ['--bogus']
    refute status.success?
  end

  def test_code_block_title_is_printed
    doc = <<~ADOC
      = Titled

      [source,bash]
      .Build the demo
      ----
      echo one
      ----
    ADOC
    script = convert doc
    content = File.read(script)
    assert_includes content, "block_01) printf '%s\\n' 'Build the demo' ;;"
    out, _status = run_script script, args: ['--yes', '--no-prose']
    assert_includes out, 'Build the demo'
  end

  def test_titled_block_hint_prefers_title
    doc = <<~ADOC
      = Titled

      [source,bash]
      .Build the demo
      ----
      echo one
      ----
    ADOC
    script = convert doc
    out, _status = run_script script, args: ['--list']
    assert_includes out, 'block_01: Build the demo'
  end

  def test_block_source_is_echoed_before_running
    out, _status = run_script @script, args: ['--yes']
    # The whole code, indented, shows before the block output.
    assert_match(/┃ block 1\/2[^\n]*\n  in [^\n]*\n╋━+\n    echo one\n╋━+\none\n/, out)
  end

  def test_multiline_block_source_is_echoed_verbatim
    doc = <<~ADOC
      = Multi

      [source,bash]
      ----
      printf '%s\\n' 'it''s $tricky'
      echo done
      ----
    ADOC
    script = convert doc
    content = File.read(script)
    assert_includes content, "runnable_print_code 'echo done'"
    out, _status = run_script script, args: ['--yes']
    assert_includes out, "    echo done\n"
  end

  def test_header_shows_working_directory_below_banner
    out, _status = run_script @script, args: ['--yes']
    banner_position = out.index('┃ block 1/')
    directory_position = out.index("  in #{Dir.pwd}\n")
    refute_nil banner_position
    refute_nil directory_position
    assert_operator banner_position, :<, directory_position
  end

  def test_directory_line_reflects_cd_from_previous_block
    doc = <<~ADOC
      = Mover

      [source,bash]
      ----
      cd /
      ----

      [source,bash]
      ----
      pwd
      ----
    ADOC
    script = convert doc
    out, _status = run_script script, args: ['--yes']
    assert_includes out, "  in /\n"
  end

  def test_blank_lines_become_echo_calls_in_runnable_block
    doc = <<~ADOC
      = Blanks

      [source,bash]
      ----
      echo one

      echo two
      ----
    ADOC
    script = convert doc
    content = File.read(script)
    assert_includes content, "echo one\necho\necho two\n"
    out, _status = run_script script, args: ['--yes']
    assert_includes out, "    echo one\n    echo\n"
    assert_includes out, "one\n\ntwo\n"
  end

  def test_blank_lines_inside_heredoc_are_kept
    doc = <<~ADOC
      = Heredoc

      [source,bash]
      ----
      cat <<EOF
      line above

      line below
      EOF
      echo done
      ----
    ADOC
    script = convert doc
    content = File.read(script)
    assert_includes content, "cat <<EOF\nline above\n\nline below\nEOF\n"
    out, _status = run_script script, args: ['--yes']
    assert_includes out, "line above\n\nline below\n"
    assert_includes out, "done\n"
  end

  def test_full_run_and_resume
    out, status = run_script @script, stdin: "\n\n"
    assert status.success?
    assert_includes out, 'one'
    assert_includes out, 'two'
    assert_includes out, 'All blocks handled.'
    progress = File.read(File.join(@dir, 'doc.sh.progress'))
    assert_match(/^block_01 done$/, progress)
    assert_match(/^block_02 done$/, progress)
  end

  def test_failure_stops_and_resume_continues
    failing = SAMPLE.sub('echo one', 'false')
    script = convert failing
    dir = @dir
    out, _status = run_script script, stdin: "\n\n"
    assert_includes out, 'Block failed with exit status 1.'
    progress = File.read(File.join(dir, 'doc.sh.progress'))
    assert_match(/^block_01 failed$/, progress)

    # Second run: skipping the failed block records it as skipped.
    out, _status = run_script script, stdin: "s\n\n"
    assert_includes out, 'All blocks handled.'
    progress = File.read(File.join(dir, 'doc.sh.progress'))
    assert_match(/^block_01 skipped$/, progress)
    assert_match(/^block_02 done$/, progress)
  end

  def test_yes_flag_is_noninteractive
    out, _status = run_script @script, stdin: '', args: ['--yes']
    assert_includes out, 'All blocks handled.'
    refute_includes out, '[Enter]'
  end

  def test_reset_flag_clears_progress
    run_script @script, stdin: "\n\n"
    _out, status = run_script @script, args: ['--reset']
    assert status.success?
    refute_path_exists File.join(@dir, 'doc.sh.progress')
  end

  def test_quitting_midway_saves_progress
    out, _status = run_script @script, stdin: "\nq\n"
    assert_includes out, 'Stopped'
    progress = File.read(File.join(@dir, 'doc.sh.progress'))
    assert_match(/^block_01 done$/, progress)
    refute_match(/^block_02/, progress)
  end

  def test_resume_skips_done_blocks
    run_script @script, stdin: "\nq\n"
    out, _status = run_script @script, stdin: "\n"
    refute_includes out, 'echo one'
    assert_includes out, 'echo two'
    assert_includes out, 'All blocks handled.'
  end

  def test_progress_file_survives_cd_in_blocks
    doc = <<~ADOC
      = Chdir

      [source,bash]
      ----
      mkdir -p sub
      cd sub
      ----
      [source,bash]
      ----
      pwd
      ----
    ADOC
    script = convert doc
    dir = @dir
    run_script script, stdin: "\n\n"
    assert_path_exists File.join(dir, 'doc.sh.progress')
  end

  def test_document_with_no_runnable_blocks
    doc = <<~ADOC
      = Nothing
      Just prose.
    ADOC
    script = convert doc
    _out, status = Open3.capture2e('bash', '-n', script)
    assert status.success?
    out, status = run_script script
    assert status.success?
    assert_includes out, 'no runnable blocks'
  end

  def test_example_document_round_trip
    example = File.join(PROJECT, 'examples', 'setup-guide.adoc')
    script = convert File.read(example), 'setup-guide.adoc'
    _out, status = Open3.capture2e('bash', '-n', script)
    assert status.success?
  end
end
# Tests for the "runnable-json" backend: the JSON document a graphical
# viewer consumes. The contract under test is the schema, not presentation.
class JsonBackendTest < Minitest::Test
  def setup
    @json = convert SAMPLE, 'doc.adoc', backend: 'runnable-json'
  end

  def test_output_is_valid_json_with_schema_version
    data = JSON.parse(File.read(@json))
    assert_equal 1, data['version']
    assert_equal 'Sample', data['title']
  end

  def test_steps_pair_context_with_blocks
    data = JSON.parse(File.read(@json))
    steps = data['steps']
    assert_equal 3, steps.size # block one, block two, tail

    first = steps[0]
    assert_equal 'prose', first['context'].first['kind']
    assert_equal 'Intro prose with bold, code, and a site (https://example.org).',
                 first['context'].first['text']
    assert_equal 'heading', first['context'][1]['kind']
    assert_equal 1, first['context'][1]['level']
    assert_equal 'First', first['context'][1]['text']
    assert_equal ['echo one'], first['block']['source']

    second = steps[1]
    kinds = second['context'].map { |item| item['kind'] }
    assert_includes kinds, 'code'
    note_items = second['context'].select { |item| item['note'] }
    assert_includes note_items.map { |item| item['note'] }, '(not run)'
    assert_includes note_items.map { |item| item['note'] }, '(python, not run)'
    assert_equal 'Do things', second['block']['title']
    assert_equal 'Do things', second['block']['hint']

    tail = steps[2]
    assert_nil tail['block']
    assert_equal 'prose', tail['context'].last['kind']
    assert_equal 'Closing prose.', tail['context'].last['text']
  end

  def test_document_with_no_blocks_has_a_single_tail_step
    doc = <<~ADOC
      = Nothing
      Just prose.
    ADOC
    json = convert doc, 'nothing.adoc', backend: 'runnable-json'
    data = JSON.parse(File.read(json))
    assert_equal 1, data['steps'].size
    assert_nil data['steps'].first['block']
  end

  def test_example_document_converts_to_valid_json
    example = File.join(PROJECT, 'examples', 'setup-guide.adoc')
    json = convert File.read(example), 'setup-guide.adoc', backend: 'runnable-json'
    data = JSON.parse(File.read(json))
    assert_equal 1, data['version']
    assert data['steps'].size >= 2
  end
end

class ShellQuotingTest < Minitest::Test
  def test_plain_text
    assert_equal "'hello'", RunnableAsciidoc.shell_single_quoted('hello')
  end

  def test_text_with_apostrophe
    quoted = RunnableAsciidoc.shell_single_quoted("it's")
    assert_equal "'it'\\''s'", quoted
  end

  def test_quoted_text_survives_bash
    text = "dona's \"tricky\" $HOME `pwd` \\ line"
    script = "printf '%s\\n' #{RunnableAsciidoc.shell_single_quoted(text)}\n"
    out = IO.popen(['bash', '-c', script], &:read)
    assert_equal text, out.chomp
  end

  def test_print_call_lines_are_printed
    # Every context line must appear inside a runnable_print* call; a bare
    # newline inside a function body prints nothing, which once silently
    # swallowed all paragraph breaks.
    text = 'a line'
    script = <<~SH
      runnable_print() { printf '%s\\n' "$1"; }
      runnable_print #{RunnableAsciidoc.shell_single_quoted(text)}
    SH
    out = IO.popen(['bash', '-c', script], &:read)
    assert_equal "a line\n", out
  end

  def test_block_function_name_padding
    assert_equal 'block_01', RunnableAsciidoc.block_function_name(1)
    assert_equal 'block_12', RunnableAsciidoc.block_function_name(12)
  end

  def test_color_helpers_emit_sgr_codes
    assert_equal "\e[1m", RunnableAsciidoc.color_bold
    assert_equal "\e[33m", RunnableAsciidoc.color_yellow
    assert_equal "\e[31m", RunnableAsciidoc.color_red
    assert_equal "\e[0m", RunnableAsciidoc.color_reset
  end

  def test_wrap_text_preserves_paragraph_breaks
    lines = RunnableAsciidoc.wrap_text("one two\n\nthree", 40)
    assert_equal ['one two', '', 'three'], lines
  end

  def test_wrap_text_long_word_kept_intact
    lines = RunnableAsciidoc.wrap_text('x' * 50, 10)
    assert_equal ['x' * 50], lines
  end

  def test_wrap_text_greedy_fill
    lines = RunnableAsciidoc.wrap_text('aa bb cc dd', 6)
    assert_equal ['aa bb', 'cc dd'], lines
  end
end
class ColorTest < Minitest::Test
  def setup
    @script = convert SAMPLE_TWO_BLOCK
  end

  def test_plain_output_has_no_escape_codes
    out, status = run_script @script, args: ['--yes']
    assert status.success?
    refute_includes out, "\e["
  end

  def test_no_color_flag_suppresses_codes_even_forced
    out, _status = run_script @script, args: ['--no-color', '--yes']
    refute_includes out, "\e["
  end

  def test_forced_color_adds_codes_despite_pipe
    out, _status = run_script @script, args: ['--color', '--yes']
    assert_includes out, "\e[1m┃ block 1/1:"
  end

  def test_banner_has_no_hint_for_untitled_block
    out, _status = run_script @script, args: ['--color', '--yes']
    assert_includes out, "\e[1m┃ block 1/1:\e[0m \n"
    refute_match(/ block 1\/1:.*echo/, out)
  end

  def test_title_shown_in_banner_when_present
    doc = <<~ADOC
      = Titled banner

      [source,bash]
      .Build the demo
      ----
      echo one
      ----
    ADOC
    script = convert doc
    out, _status = run_script script, args: ['--yes']
    assert_includes out, "┃ block 1/1: Build the demo"
    refute_includes out, "Build the demo\n┃ block 1/1"
  end

  def test_failure_line_is_painted_red_when_forced
    failing = SAMPLE_TWO_BLOCK.sub('echo more', 'false')
    script = convert failing
    out, _status = run_script script, args: ['--color', '--yes']
    assert_match(/Block failed with exit status 1/, out)
    assert_includes out, "\e[31m  Block failed with exit status 1.\e[0m\n"
  end

  def test_prompt_painted_bold_on_tty
    out, _status = PtyRun.run @script, answers: ['', 'q']
    assert_includes out, "\e[1m┃ block 1/1:"
    assert_includes out, "\e[1m[Enter] run · [s] skip · [q] quit > "
    refute_match(/ block 1\/1:.*things/, out) # untitled: no hint in banner
    assert_includes out, 'things' # the block still runs
  end

  def test_interactive_stop_notice_is_painted_on_tty
    doc = <<~ADOC
      = Stopper

      [source,bash]
      .Paint check
      ----
      echo one
      ----
    ADOC
    script = convert doc
    out, _status = PtyRun.run script, answers: ['q']
    assert_includes out, "\e[1m[Enter] run · [s] skip · [q] quit > "
    assert_match(/Stopped before block 1.*resume\.\e\[0m\r?\n/, out)
  end

  def test_list_paints_header_and_names_when_forced
    out, _status = run_script @script, args: ['--color', '--list']
    assert_includes out, "\e[1mRunnable blocks:\e[0m\n"
    assert_includes out, "\e[1mblock_01:\e[0m echo things"
  end
end
