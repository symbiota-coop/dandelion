// The options every FullCalendar calendar shares (events/_calendar.erb, the design guide), merged under a calendar's own.
// FullCalendar's elements have no class names of their own, so the *Class options add ours, alongside its Bootstrap 5
// theme's, for app.css to style
function calendarOptions (options) {
  return Object.assign({
    headerToolbar: {
      start: 'today prev,next title',
      end: 'dayGridMonth,listMonth'
    },
    buttons: {
      today: { text: 'Today' },
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
