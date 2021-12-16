/*
Template Name: Infinite Admin - Responsive Admin Dashboard Template build with Twitter Bootstrap 3.3.7 & Bootstrap 4
Version: 1.3.0
Author: Sean Ngu
Website: http://www.seantheme.com/infinite-admin/admin/html/
*/

var handleRenderTableData = function() {
	var rowReorderOption = ($(window).width() > 767) ? true : false;
	var table = $('#datatables-default').DataTable({
		dom: "<'row'<'col-sm-3'l><'col-sm-9 text-right'<'m-l-10 pull-right'B>f>>rt<'pull-left'i>p",
		'lengthMenu': [ 20, 40, 60, 80, 100 ],
		colReorder: true,
		fixedHeader: {
			header: true,
			headerOffset: $('#header').height()
		},
		keys: true,
		responsive: true,
		rowReorder: rowReorderOption,
		buttons: [ 
			{ extend: 'copy', className: 'btn btn-default btn-sm' },
			{ extend: 'print', className: 'btn btn-default btn-sm' },
			{ extend: 'excel', className: 'btn btn-default btn-sm' },
			{ extend: 'pdf', className: 'btn btn-default btn-sm' }
		],
		"columnDefs": [{
			"targets": 'no-sort',
			"orderable": false,
			"order": []
		}],
		"order": [[ 1, "asc" ]]
	});
	table.on('order.dt search.dt', function () {
		table.column(0, {search:'applied', order:'applied'}).nodes().each( function (cell, i) {
			cell.innerHTML = (i+1) + '.';
		});
	}).draw();
};


/* Controller
------------------------------------------------ */
var TableData = function () {
	"use strict";
	
	return {
		//main function
		init: function () {
			handleRenderTableData();
		}
	};
}();