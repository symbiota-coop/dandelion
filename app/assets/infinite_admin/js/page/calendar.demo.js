/*
Template Name: Infinite Admin - Responsive Admin Dashboard Template build with Twitter Bootstrap 3.3.7 & Bootstrap 4
Version: 1.3.0
Author: Sean Ngu
Website: http://www.seantheme.com/infinite-admin/admin/html/
*/

var handleRenderFullcalendar = function() {
	$('#external-events .fc-event').each(function() {
		$(this).data('event', {
			title: $.trim($(this).text()),
			stick: true
		});
		$(this).draggable({
			zIndex: 999,
			revert: true,
			revertDuration: 0
		});
	});
	
	var initialLocaleCode = 'en';
	var d = new Date();
	var month = d.getMonth() + 1;
		month = (month < 10) ? '0' + month : month;
	var year = d.getFullYear();
	var day = d.getDate();
	var today = moment().startOf('day');
	var contentHeight = $(window).height() - $('#calendar').offset().top - 70;
	$('#calendar').fullCalendar({
		header: {
			left: 'prev,next today',
			center: 'title',
			right: 'month,agendaWeek,agendaDay,listMonth'
		},
		defaultDate: today,
		navLinks: true,
		businessHours: true,
		locale: initialLocaleCode,
		editable: true,
		droppable: true,
		contentHeight: contentHeight,
		events: [{
			title: 'Trip to London',
			start: year + '-'+ month +'-01',
			end: year + '-'+ month +'-05'
		},{
			title: 'Meet with Riki',
			start: year + '-'+ month +'-02T06:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'Meet with Harve',
			start: year + '-'+ month +'-02T12:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'Stonehenge, Windsor Castle, Oxford',
			start: year + '-'+ month +'-05T08:45:00',
			color: PRIMARY_COLOR
		},{
			title: 'Paris Trip',
			start: year + '-'+ month +'-12',
			end: year + '-'+ month +'-18'
		},{
			title: 'Domain name due',
			start: year + '-'+ month +'-15',
			color: PRIMARY_COLOR
		},{
			title: 'Cambridge Trip',
			start: year + '-'+ month +'-19'
		},{
			title: 'Visit Apple Company',
			start: year + '-'+ month +'-22T05:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'Exercise Class',
			start: year + '-'+ month +'-22T07:30:00',
			color: PRIMARY_COLOR
		},{
			title: 'Live Recording',
			start: year + '-'+ month +'-22T03:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'New Android App Discussion',
			start: year + '-'+ month +'-25T08:00:00',
			end: year + '-'+ month +'-25T10:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'Marketing Plan Presentation',
			start: year + '-'+ month +'-25T12:00:00',
			end: year + '-'+ month +'-25T14:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'Chase due',
			start: year + '-'+ month +'-26T12:00:00',
			color: WARNING_COLOR
		},{
			title: 'Heartguard',
			start: year + '-'+ month +'-26T08:00:00',
			color: WARNING_COLOR
		},{
			title: 'Lunch with Richard',
			start: year + '-'+ month +'-28T14:00:00',
			color: PRIMARY_COLOR
		},{
			title: 'Web Hosting due',
			start: year + '-'+ month +'-30',
			color: PRIMARY_COLOR
		}]
	});
	
	// build the locale selector's options
	$.each($.fullCalendar.locales, function(localeCode) {
		$('#locale-selector').append(
			$('<option/>')
				.attr('value', localeCode)
				.prop('selected', localeCode == initialLocaleCode)
				.text(localeCode)
		);
	});

	// when the selected option changes, dynamically change the calendar option
	$('#locale-selector').on('change', function() {
		if (this.value) {
			$('#calendar').fullCalendar('option', 'locale', this.value);
		}
	});
};


/* Controller
------------------------------------------------ */
var Calendar = function () {
	"use strict";
	
	return {
		//main function
		init: function () {
			handleRenderFullcalendar();
		}
	};
}();