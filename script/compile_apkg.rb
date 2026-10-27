#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "sqlite3"
require "tmpdir"
require "zlib"
require_relative "lib/color"

class AnkiCompiler
  SCHEMA = <<~SQL
    CREATE TABLE col (
      id integer primary key, crt integer not null, mod integer not null, scm integer not null,
      ver integer not null, dty integer not null, usn integer not null, ls integer not null,
      conf text not null, models text not null, decks text not null, dconf text not null, tags text not null
    );
    CREATE TABLE notes (
      id integer primary key, guid text not null, mid integer not null, mod integer not null,
      usn integer not null, tags text not null, flds text not null, sfld text not null,
      csum integer not null, flags integer not null, data text not null
    );
    CREATE TABLE cards (
      id integer primary key, nid integer not null, did integer not null, ord integer not null,
      mod integer not null, usn integer not null, type integer not null, queue integer not null,
      due integer not null, ivl integer not null, factor integer not null, reps integer not null,
      lapses integer not null, left integer not null, odue integer not null, odid integer not null,
      flags integer not null, data text not null
    );
    CREATE TABLE revlog (
      id integer primary key, cid integer not null, usn integer not null, ease integer not null,
      ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null
    );
    CREATE TABLE graves ( usn integer not null, oid integer not null, type integer not null );
    CREATE INDEX ix_notes_usn on notes (usn);
    CREATE INDEX ix_cards_usn on cards (usn);
    CREATE INDEX ix_cards_nid on cards (nid);
    CREATE INDEX ix_cards_sched on cards (did, queue, due);
    CREATE INDEX ix_notes_csum on notes (csum);
  SQL

  def initialize(input_path:, media_dir:, output_path:)
    @input_path  = input_path
    @media_dir   = media_dir
    @output_path = File.expand_path(output_path)
    @now_sec     = Time.now.to_i
    @now_ms      = (Time.now.to_f * 1000).to_i
    @id_counter  = @now_ms
  end

  def run
    abort "Error: #{@input_path} not found" unless File.file?(@input_path)

    puts Color.bold("==> Compiling Anki package from #{@input_path}...")
    deck_data = JSON.parse(File.read(@input_path))

    Dir.mktmpdir("anki_apkg_") do |tmp_dir|
      build_collection(deck_data, tmp_dir)
      bundle_apkg(tmp_dir)
    end
  end

  private

  def next_id = (@id_counter += 1)

  def build_collection(data, tmp_dir)
    db = SQLite3::Database.new(File.join(tmp_dir, "collection.anki2"))
    db.execute_batch(SCHEMA)

    top_name = data["name"]
    top_did  = Zlib.crc32(data["crowdanki_uuid"])

    # Dynamically extract all child decks from deck.json
    child_decks = (data["children"] || []).each_with_object({}) do |child, map|
      did = Zlib.crc32(child["crowdanki_uuid"])
      map[child["name"]] = { id: did, name: "#{top_name}::#{child['name']}" }
    end

    # Format models and decks payloads
    models_payload = (data["note_models"] || []).each_with_object({}) do |raw_model, map|
      mid = Zlib.crc32(raw_model["crowdanki_uuid"])
      map[mid.to_s] = format_model(raw_model, mid, top_did)
    end

    decks_payload = { "1" => deck_record(1, "Default", usn: 0), top_did.to_s => deck_record(top_did, top_name) }
    child_decks.each_value { |deck| decks_payload[deck[:id].to_s] = deck_record(deck[:id], deck[:name]) }

    primary_model_id = models_payload.keys.first.to_i
    db.execute(
      "INSERT INTO col VALUES(1, 1411124400, ?, ?, 11, 0, 0, 0, ?, ?, ?, '{}', '{}')",
      [@now_ms, @now_ms, JSON.dump(collection_conf(primary_model_id)), JSON.dump(models_payload), JSON.dump(decks_payload)]
    )

    insert_notes_and_cards(db, data, models_payload, child_decks, top_did)
    db.close
  end

  def insert_notes_and_cards(db, data, models_payload, child_decks, top_did)
    notes = extract_unique_notes(data)
    puts "Found #{Color.cyan(notes.size)} unique notes."

    card_counts = Hash.new(0)

    db.transaction do
      note_stmt = db.prepare("INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?,?)")
      card_stmt = db.prepare("INSERT INTO cards VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")

      notes.each_value do |n|
        note_id  = next_id
        mid      = Zlib.crc32(n["note_model_uuid"])
        model    = models_payload[mid.to_s] || models_payload.values.first
        sfld     = n["fields"].first.to_s
        flds     = n["fields"].join("\x1f")
        csum     = Digest::SHA1.hexdigest(sfld)[0..7].to_i(16)
        tags     = n["tags"]&.any? ? " #{n['tags'].join(' ')} " : ""

        note_stmt.execute(note_id, n["guid"], mid, @now_sec, -1, tags, flds, sfld, csum, 0, "")

        # Dynamically route each template's card to its matching child deck
        model[:tmpls].each do |tmpl|
          matched_child = child_decks.find { |child_name, _| tmpl[:name].downcase.include?(child_name.downcase) }
          target_did    = matched_child ? matched_child[1][:id] : top_did
          deck_label    = matched_child ? matched_child[0] : "Top"

          card_stmt.execute(next_id, note_id, target_did, tmpl[:ord], @now_sec, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "")
          card_counts[deck_label] += 1
        end
      end
    end

    counts_summary = card_counts.map { |label, count| "#{Color.green(count)} #{label}" }.join(", ")
    puts "Generated #{counts_summary} cards."
  end

  def extract_unique_notes(data)
    notes = {}
    (data["notes"] || []).each { |n| notes[n["guid"]] = n }
    (data["children"] || []).each do |child|
      (child["notes"] || []).each { |n| notes[n["guid"]] ||= n }
    end
    notes
  end

  def bundle_apkg(tmp_dir)
    media_files = File.directory?(@media_dir) ? Dir.glob(File.join(@media_dir, "*")).select { |f| File.file?(f) } : []
    puts "Indexing #{Color.cyan(media_files.size)} media assets from '#{@media_dir}'..."

    media_map = {}
    media_files.each_with_index do |src, idx|
      key = idx.to_s
      media_map[key] = File.basename(src)
      FileUtils.ln_s(File.expand_path(src), File.join(tmp_dir, key))
    end
    File.write(File.join(tmp_dir, "media"), JSON.dump(media_map))

    File.delete(@output_path) if File.exist?(@output_path)
    puts Color.bold("==> Packaging #{@output_path}...")

    Dir.chdir(tmp_dir) do
      system("zip", "-q", "-0", @output_path, "collection.anki2", "media", *media_map.keys) || abort("Error: Failed to create zip package")
    end

    mb = (File.size(@output_path).to_f / (1024 * 1024)).round(2)
    puts Color.green("✓ Successfully generated #{@output_path} (#{mb} MB)!")
  end

  def deck_record(id, name, usn: -1)
    {
      id: id, name: name, mod: @now_sec, usn: usn, collapsed: false,
      conf: 1, desc: "", dyn: 0, extendNew: 10, extendRev: 50,
      newToday: [0, 0], revToday: [0, 0], lrnToday: [0, 0], timeToday: [0, 0]
    }
  end

  def collection_conf(model_id)
    {
      activeDecks: [1], addToCur: true, collapseTime: 1200, curDeck: 1,
      curModel: model_id.to_s, dueCounts: true, estTimes: true, newBury: true,
      newSpread: 0, nextPos: 1, sortBackwards: false, sortType: "noteFld", timeLim: 0
    }
  end

  def format_model(raw, model_id, top_did)
    {
      id: model_id, name: raw["name"], type: 0, mod: @now_sec, usn: -1, sortf: 0, did: top_did,
      tmpls: raw["tmpls"].map.with_index { |t, i| { name: t["name"], ord: i, qfmt: t["qfmt"], afmt: t["afmt"], bqfmt: "", bafmt: "", did: nil, bfont: "", bsize: 0 } },
      flds: raw["flds"].map.with_index { |f, i| { name: f["name"], ord: i, sticky: false, rtl: false, font: "Arial", size: 20, media: [] } },
      css: raw["css"] || "",
      latexPre: "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
      latexPost: "\\end{document}",
      latexsvg: false,
      req: raw["req"]
    }
  end
end

def parse_cli
  options = { input: "deck.json", media: "media", output: "Katakana_Practice.apkg" }
  OptionParser.new do |opts|
    opts.banner = "Usage: compile_apkg.rb [options]"
    opts.on("-i", "--input PATH",  "Input deck.json (default: deck.json)") { |v| options[:input] = v }
    opts.on("-m", "--media PATH",  "Media directory (default: media)")      { |v| options[:media] = v }
    opts.on("-o", "--output PATH", "Output APKG path (default: Katakana_Practice.apkg)") { |v| options[:output] = v }
  end.parse!
  options
end

if __FILE__ == $PROGRAM_NAME
  opts = parse_cli
  opts[:output] = opts[:output].sub(/\.apkg$/i, '') + '.apkg' unless opts[:output].downcase.end_with?('.apkg')
  AnkiCompiler.new(
    input_path:  opts[:input],
    media_dir:   opts[:media],
    output_path: opts[:output]
  ).run
end
