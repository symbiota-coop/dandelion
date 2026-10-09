// Suggests places as someone types a location. The field stays an ordinary input, so free text still works:
// jQuery UI shows the menu and the Places API (New) fills it. Google requires its attribution under suggestions
// shown without a map, which app.css adds to the menu
function placeAutocomplete (input, options = {}) { // eslint-disable-line no-unused-vars
  const $input = $(input)
  if (!$input.length) return

  // A session groups the requests made while typing one location with the selection that ends it, for billing
  let sessionToken = null

  $input.autocomplete({
    minLength: 2,
    delay: 250,
    classes: { 'ui-autocomplete': 'places-autocomplete' },
    source: function (request, response) {
      google.maps.importLibrary('places')
        .then(function (places) {
          sessionToken ||= new places.AutocompleteSessionToken()
          return places.AutocompleteSuggestion.fetchAutocompleteSuggestions({ input: request.term, sessionToken: sessionToken })
        })
        .then(function (result) {
          response(result.suggestions.filter(s => s.placePrediction).map(s => s.placePrediction.text.toString()))
        })
        .catch(function (error) {
          console.error('Error loading place suggestions:', error)
          response([])
        })
    },
    select: function (e, ui) {
      sessionToken = null
      $input.val(ui.item.value)
      if (options.select) options.select(ui.item.value)
      return false
    }
  })

  // Enter picks the highlighted suggestion. With the menu open and nothing highlighted, it closes the menu rather than submitting the form
  $input.on('keydown', function (e) {
    if (e.which === 13 && $input.autocomplete('widget').is(':visible')) {
      e.preventDefault()
      $input.autocomplete('close')
    }
  })
}
