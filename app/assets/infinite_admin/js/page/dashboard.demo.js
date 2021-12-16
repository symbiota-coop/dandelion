/*
Template Name: Infinite Admin - Responsive Admin Dashboard Template build with Twitter Bootstrap 3.3.7 & Bootstrap 4
Version: 1.3.0
Author: Sean Ngu
Website: http://www.seantheme.com/infinite-admin/admin/html/
*/


var handleDashboardChart = function() { 
	Chart.defaults.global.defaultFontColor = 'rgba(255,255,255,0.5)';
	Chart.defaults.global.defaultFontSize = 10;
	Chart.defaults.global.defaultFontStyle = 'bold';
	
	var ctx = document.getElementById('barChart');
	var barChart = new Chart(ctx, {
		type: 'bar',
		data: {
			labels: ['S','M','T','W','T','F','S'],
			datasets: [{
				label: 'Total Visitors',
				data: [37,31,36,34,43,31,50],
				backgroundColor: WARNING_COLOR,
				borderColor: 'transparent'
			}]
		},
		options: {
			maintainAspectRatio: false,
			legend: {
				display: false
			},
			tooltips: {
				callbacks: {
					title: function(tooltipItems, data) { 
						var tooltipTitle = '';
						switch (tooltipItems[0].index) {
							case 0: tooltipTitle = 'Sunday'; break;
							case 1: tooltipTitle = 'Monday'; break;
							case 2: tooltipTitle = 'Tuesday'; break;
							case 3: tooltipTitle = 'Wednesday'; break;
							case 4: tooltipTitle = 'Thursday'; break;
							case 5: tooltipTitle = 'Friday'; break;
							case 6: tooltipTitle = 'Saturday'; break;
						}
						return tooltipTitle;
					},
					labelColor: function(tooltipItem, chart) {
						return {
							borderColor: 'transparent',
							backgroundColor: WHITE_TRANSPARENT_5_COLOR
						};
					}
				}
			},
			scales: {
				yAxes: [{
					gridLines: {
						borderDashOffset: 8,
						drawTicks: false,
						drawBorder: false,
						color: 'rgba(255,255,255,0.3)',
						borderDash: [4],
					},
					ticks: {
						display: false
					}
				}],
				xAxes: [{
					barPercentage: 0.4,
					gridLines : {
						display : false
					}
				}]
			}
		}
	});
};

var handleNotification = function() {
	$.notification({
		title: 'New Mail',
		content: 'You have 20+ new mail in your Inbox',
		icon: 'ti-email',
		iconClass: 'bg-gradient-blue'
	});
};


/* Controller
------------------------------------------------ */
var Dashboard = function () {
	"use strict";
	
	return {
		//main function
		init: function () {
			handleDashboardChart();
			handleNotification();
		}
	};
}();