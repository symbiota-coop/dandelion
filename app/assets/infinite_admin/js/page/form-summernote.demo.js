/*
Template Name: Infinite Admin - Responsive Admin Dashboard Template build with Twitter Bootstrap 3.3.7 & Bootstrap 4
Version: 1.3.0
Author: Sean Ngu
Website: http://www.seantheme.com/infinite-admin/admin/html/
*/

var handleRenderSummernote = function() {
	var totalHeight = $(window).height() - $('.summernote').offset().top - 155;
	$('.summernote').summernote({
		height: totalHeight
	});
};


/* Controller
------------------------------------------------ */
var FormSummernote = function () {
	"use strict";
	
	return {
		//main function
		init: function () {
			handleRenderSummernote();
		}
	};
}();