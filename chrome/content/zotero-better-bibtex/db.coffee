Zotero.BetterBibTeX.DB = new class
  constructor: ->
    @db = new loki('betterbibtex.db', {
      autosave: true
      autosaveInterval: 10000
      adapter: @adapter
      env: 'BROWSER'
    })

    @db.loadDatabase()

    if !@db.getCollection('cache')
      @cache = @db.addCollection('cache', { indices: ['itemID', 'exportCharset', 'exportNotes', 'getCollections', 'translatorID', 'useJournalAbbreviation', 'citekey'] })

    if !@db.getCollection('serialized')
      @serialized = @db.addCollection('serialized', { indices: ['itemID', 'uri'] })

    if !@db.getCollection('keys')
      @keys = @db.addCollection('keys', {indices: ['itemID', 'libraryID', 'citekey', 'citekeyFormat']})

    if !@db.getCollection('autoexport')
      @autoexport = @db.addCollection('autoexport', {indices: ['collection', 'path', 'exportCharset', 'exportNotes', 'translatorID', 'useJournalAbbreviation', 'exportedRecursively']})

    # # in case I need to update the indices:
    # #
    # # remove all binary indexes
    # coll.binaryIndices = {}
    # # Unique indexes are not saved but their names are (to be rebuilt on every load)
    # # This will remove all unique indexes on the next save/load cycle
    # coll.uniqueNames = []
    # # add binary index
    # coll.ensureIndex("lastname")
    # # add unique index
    # coll.ensureUniqueIndex("userId")

    metadata = @db.getCollection('metadata')
    @upgradeNeeded = !metadata || !metadata[0] ||
      metadata.data[0].Zotero != ZOTERO_CONFIG.VERSION ||
      metadata.data[0].BetterBibTeX != Zotero.BetterBibTeX.release

    cacheReset = Zotero.BetterBibTeX.pref.get('cacheReset')
    if @upgradeNeeded || cacheReset > 0
      @serialized.removeDataOnly()
      @cache.removeDataOnly()
      if cacheReset > 0
        Zotero.BetterBibTeX.pref.set('cacheReset', cacheReset - 1)
        Zotero.BetterBibTeX.debug('cache.load forced reset', cacheReset - 1, 'left')

    @keys.on('insert', (key) =>
      if !key.citekeyFormat && Zotero.BetterBibTeX.pref.get('keyConflictPolicy') == 'change'
        # removewhere will trigger 'delete' for the conflicts, which will take care of their cache dependents
        @keys.removeWhere((o) -> o.citekey == key.citekey && o.libraryID == key.libraryID && o.itemID != key.itemID && o.citekeyFormat)
    )
    @keys.on('update', (key) =>
      if !key.citekeyFormat && Zotero.BetterBibTeX.pref.get('keyConflictPolicy') == 'change'
        @keys.removeWhere((o) -> o.citekey == key.citekey && o.libraryID == key.libraryID && o.itemID != key.itemID && o.citekeyFormat)

      @cache.remove({itemID: key.itemID})
    )
    @keys.on('delete', (key) =>
      @remove({itemID: key.itemID})
    )

    idleService = Components.classes['@mozilla.org/widget/idleservice;1'].getService(Components.interfaces.nsIIdleService)
    idleService.addIdleObserver({observe: (subject, topic, data) => @save() if topic == 'idle'}, 5)

  touch: (itemID) ->
    @cache.remove({itemID})
    @serialized.remove({itemID})
    @keys.removeWhere((o) -> o.itemID == itemID && o.citekeyFormat)

  save: (force) ->
    return unless force || @db.autosaveDirty()

    @db.removeCollection('metadata')
    metadata = @db.addCollection('metadata')
    metadata.insert({Zotero: ZOTERO_CONFIG.VERSION, BetterBibTeX: Zotero.BetterBibTeX.release})

    @db.save((err) ->
      throw(err) if (err)
    )
    @db.autosaveClearFlags()

  adapter:
    saveDatabase: (name, serialized, callback) ->
      file = Zotero.getZoteroDirectory()
      file.append("#{name}.json")
      stream = FileUtils.openAtomicFileOutputStream(@file(), FileUtils.MODE_WRONLY | FileUtils.MODE_CREATE | FileUtils.MODE_TRUNCATE)
      stream.write(serialized, serialized.length)
      stream.close()
      callback(true)

    loadDatabase: (name, callback) ->
      file = Zotero.getZoteroDirectory()
      file.append("#{name}.json")
      if file.exists()
        callback(Zotero.File.getContents(file))
      else
        callback(null)

  SQLite:
    parseTable: (name) ->
      name = name.split('.')
      switch name.length
        when 1
          schema = ''
          name = name[0]
        when 2
          schema = name[0] + '.'
          name = name[1]
      name = name.slice(1, -1) if name[0] == '"'
      return {schema: schema, name: name}

    table_info: (table) ->
      table = @parseTable(table)
      statement = Zotero.DB.getStatement("pragma #{table.schema}table_info(\"#{table.name}\")", null, true)

      fields = (statement.getColumnName(i).toLowerCase() for i in [0...statement.columnCount])

      columns = {}
      while statement.executeStep()
        values = (Zotero.DB._getTypedValue(statement, i) for i in [0...statement.columnCount])
        column = {}
        for name, i in fields
          column[name] = values[i]
        columns[column.name] = column
      statement.finalize()

      return columns

    columnNames: (table) ->
      return Object.keys(@table_info(table))

    tableExists: (name) ->
      table = @parseTable(name)
      return (Zotero.DB.valueQuery("SELECT count(*) FROM #{table.schema}sqlite_master WHERE type='table' and name=?", [table.name]) != 0)

    Set: (values) -> '(' + ('' + v for v in values).join(', ') + ')'

    migrate: ->
      db = Zotero.getZoteroDatabase('betterbibtexcache')
      db.remove() if db.exists()

      db = Zotero.getZoteroDatabase('betterbibtex')
      return unless db.exists()

      Zotero.BetterBibTeX.flash('Better BibTeX: updating database', 'Updating database, this could take a while')

      Zotero.DB.query('ATTACH ? AS betterbibtex', [db.path])

      # the context stuff was a mess
      if @tableExists('betterbibtex.autoexport') && !@table_info('betterbibtex.autoexport').context
        Zotero.BetterBibTeX.DB.autoexport.removeDataOnly()

        if @table_info('betterbibtex.autoexport').collection
          Zotero.DB.query("update betterbibtex.autoexport set collection = (select 'library:' || libraryID from groups where 'group:' || groupID = collection) where collection like 'group:%'")
          Zotero.DB.query("update betterbibtex.autoexport set collection = 'collection:' || collection where collection <> 'library' and collection not like '%:%'")

        for row in Zotero.DB.query('select * from betterbibtex.autoexport')
          Zotero.BetterBibTeX.DB.autoexport.insert({
            collection: row.collection
            path: row.path
            exportCharset: row.exportCharset
            exportNotes: (row.exportNotes == 'true')
            translatorID: row.translatorID
            useJournalAbbreviation: (row.useJournalAbbreviation == 'true')
            exportedRecursively: (row.exportedRecursively == 'true')
            status: 'pending'
          })

      @keymanager.load()
      @keymanager.clearDynamic()

      if @tableExists('betterbibtex.keys')
        Zotero.BetterBibTeX.DB.keys.removeDataOnly()
        pinned = @table_info('betterbibtex.autoexport').pinned

        for row in Zotero.DB.query('select k.*, i.libraryID from betterbibtex.keys k join items i on k.itemID = i.itemID')
          if pinned
            continue unless row.pinned == 1
          else
            continue if row.citekeyFormat

          Zotero.BetterBibTeX.DB.keys.insert({
            itemID: parseInt(row.itemID)
            citekey: row.citekey
            citekeyFormat: null
            libraryID: row.libraryID
          })

      Zotero.DB.query('DETACH betterbibtex')

      db.moveTo(null, 'betterbibtex.sqlite.bak')

      @flash('Better BibTeX: database updated', 'Database update finished')
      @flash('Better BibTeX: cache has been reset', 'Cache has been reset due to a version upgrade. First exports after upgrade will be slower than usual')
