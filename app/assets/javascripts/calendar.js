/* global FullCalendar */

// The options every FullCalendar calendar shares (events/_calendar.erb, the design guide), merged under a calendar's own.
// FullCalendar's elements have no class names of their own, so the *Class options add ours, alongside its Bootstrap 5
// theme's, for app.css to style. Events take the theme's eventColor, --bs-primary, which is --theme-500
function calendarOptions (options) {
  return Object.assign({
    headerToolbar: {
      start: 'today prev,next title',
      end: 'dayGridMonth,listMonth'
    },
    buttons: {
      today: { text: 'Today', className: 'd-none d-md-inline-block' },
      dayGridMonth: { text: 'Month' },
      listMonth: { text: 'List' }
    },
    height: 'auto',
    toolbarTitleClass: 'calendar-title',
    buttonClass: function (info) {
      return 'calendar-button calendar-button-' + info.name
    },
    dayHeaderInnerClass: 'calendar-day-label',
    listDayHeaderInnerClass: 'calendar-day-label',
    dayCellClass: function (info) {
      return info.isToday ? 'calendar-today' : ''
    },
    dayCellTopInnerClass: 'calendar-day-number',
    eventClass: 'calendar-event'
  }, options)
}

// An organisation's events (events/_calendar.erb), from the data attributes of its #calendar: the events.json to load
// them from, the view and date to open on, and in embeds (data-embed) the organisation's own colour, with events opening
// in the parent window
document.addEventListener('DOMContentLoaded', function () {
  var calendarEl = document.querySelector('#calendar[data-events-url]')
  if (!calendarEl) return
  var data = calendarEl.dataset

  var options = calendarOptions({
    initialView: data.view,
    initialDate: data.date || undefined,
    events: function (fetchInfo, successCallback, failureCallback) {
      // The page's own filters, with the dates FullCalendar is showing
      var params = $.deparam(window.location.search.substring(1))
      params.from = fetchInfo.start.toISOString().split('T')[0]
      params.to = fetchInfo.end.toISOString().split('T')[0]
      $.getJSON(data.eventsUrl + '?' + $.param(params))
        .then(function (events) {
          successCallback(events.map(function (event) {
            // Multi-day events show on their start day only, as all-day events
            var isMultiDay = new Date(event.start_time).toDateString() !== new Date(event.end_time).toDateString()
            return {
              id: event.id,
              title: isMultiDay ? event.name + ' starts' : event.name,
              start: event.start_time,
              end: isMultiDay ? null : event.end_time,
              allDay: isMultiDay,
              url: '/e/' + event.slug,
              extendedProps: {
                location: event.location,
                when_details: event.when_details
              }
            }
          }))
        })
        .catch(function (error) {
          console.error('Error fetching events:', error)
          failureCallback(error)
        })
    },
    eventClick: data.embed && function (info) {
      // Cmd or ctrl-click still opens a new tab
      if (info.jsEvent.metaKey || info.jsEvent.ctrlKey) return
      window.open(info.event.url, '_parent')
      info.jsEvent.preventDefault()
    },
    eventDidMount: function (info) {
      var location = info.event.extendedProps.location
      var locationIcon = location === 'Online' ? '<i class="bi bi-camera-video-fill"></i> ' : '<i class="bi bi-geo-alt-fill"></i> '
      $(info.el).tooltip({
        title: '<strong>' + info.event.title + '</strong><br>' +
          (location ? locationIcon + location + '<br>' : '') +
          '<small>' + info.event.extendedProps.when_details + '</small>',
        html: true,
        placement: 'top',
        trigger: 'hover',
        container: 'body'
      })
    },
    allDayText: 'All day',
    aspectRatio: 1.8
  })
  // Set only when there is one: an undefined eventColor would replace the theme's
  if (data.eventColor) options.eventColor = data.eventColor
  new FullCalendar.Calendar(calendarEl, options).render()
})
