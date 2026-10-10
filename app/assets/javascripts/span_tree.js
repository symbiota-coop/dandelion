// Span trees (.span-tree tables on /stats/transactions and /stats/traces/:id), drawn like Sentry's trace view,
// with branches that open and shut and headers that sort.
// Rows carry data-id and data-parent, and each row's label has one .span-tree-guide per level above it
// (see stats/_span_tree.erb and traces.css).

// Sets each guide's connector: a line runs down from each parent past its children, and each child joins it
// with an elbow, ├ or, for the last child, └ where the line stops. Which child is last depends on the order,
// so call this again after reordering rows.
window.drawSpanTreeGuides = function(table) {
  var rows = $(table).find('tbody tr').get()
  var parentOf = {}
  var lastChildOf = {}
  rows.forEach(function(row) {
    parentOf[row.dataset.id] = row.dataset.parent
    lastChildOf[row.dataset.parent] = row.dataset.id
  })

  rows.forEach(function(row) {
    // The row and its ancestors, from the top down
    var chain = [row.dataset.id]
    while (parentOf[chain[0]]) chain.unshift(parentOf[chain[0]])

    $(row).find('.span-tree-guide').each(function(i) {
      // Guide i holds the line of chain[i]'s children; chain[i + 1] is the one on this row's path
      var id = chain[i + 1]
      var last = lastChildOf[chain[i]] === id
      var kind = id === row.dataset.id ? (last ? 'elbow' : 'tee') : (last ? '' : 'line')
      this.className = 'span-tree-guide ' + kind
    })
  })
}

$(function() {
  $('.span-tree').each(function() { drawSpanTreeGuides(this) })

  // Headers with data-sort sort by that data attribute of the rows, and again the other way. Sorting reorders
  // each row's children among themselves, so the tree stays a tree. The table's data-sort and data-sort-dir say how
  // its rows came sorted from the server.
  // DataTables' classes, so the headers show its sort icons
  function showSort(table) {
    table.find('th').removeClass('dt-ordering-asc dt-ordering-desc')
    table.find('th[data-sort="' + table.data('sort') + '"]').addClass(table.data('sort-dir') > 0 ? 'dt-ordering-asc' : 'dt-ordering-desc')
  }
  $('.span-tree').each(function() { showSort($(this)) })
  $(document).on('click', '.span-tree th[data-sort]', function() {
    var table = $(this).closest('table')
    var key = $(this).data('sort')
    // Names and starts go up first, times down
    var dir = table.data('sort') === key ? -table.data('sort-dir') : (key === 'name' || key === 'start' ? 1 : -1)
    table.data('sort', key).data('sort-dir', dir)

    var tbody = table.children('tbody')
    var byParent = {}
    tbody.children('tr').each(function() { (byParent[this.dataset.parent] = byParent[this.dataset.parent] || []).push(this) })
    var ordered = []
    ;(function add(parentId) {
      (byParent[parentId] || []).sort(function(a, b) {
        var x = $(a).data(key)
        var y = $(b).data(key)
        return (key === 'name' ? String(x).localeCompare(String(y)) : x - y) * dir
      }).forEach(function(row) {
        ordered.push(row)
        add(row.dataset.id)
      })
    })('')
    tbody.append(ordered)
    drawSpanTreeGuides(table)
    showSort(table)
  })

  // A pill shuts its row's descendants, and opens its children again along with whatever was open below them
  function children(table, id) { return $(table).find('tr[data-parent="' + id + '"]') }
  function hide(table, id) { children(table, id).each(function() { $(this).hide(); hide(table, this.dataset.id) }) }
  function show(table, id) {
    children(table, id).each(function() {
      $(this).show()
      if (!$(this).hasClass('collapsed')) show(table, this.dataset.id)
    })
  }
  $(document).on('click', '.span-tree .span-tree-toggle', function() {
    var table = $(this).closest('table')
    var row = $(this).closest('tr')
    row.toggleClass('collapsed')
    row.hasClass('collapsed') ? hide(table, row[0].dataset.id) : show(table, row[0].dataset.id)
  })
})
