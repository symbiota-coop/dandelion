// Map functionality
window.DandelionMap = {
  mapOptions: {
    mapTypeControl: false,
    scaleControl: true,
    streetViewControl: false,
    fullscreenControl: false,
    maxZoom: 16,
    minZoom: 1,
    gestureHandling: 'greedy',
    clickableIcons: false,
    disableDoubleClickZoom: false
  },

  // Google Maps needs a plain colour, so resolve --color-orange-400 when a polygon is drawn
  get polygonStyle () {
    const color = cssColor('var(--color-orange-400)')
    return {
      strokeColor: color,
      strokeOpacity: 0.8,
      strokeWeight: 2,
      fillColor: color,
      fillOpacity: 0.35
    }
  },

  // Model configurations for map markers: app.css draws a .map-marker pin in the colour, with the icon on it
  models: [
    { name: 'Account', color: 'var(--color-green-500)', icon: 'bi bi-person-fill' },
    { name: 'ActivityApplication', color: 'var(--color-green-500)', icon: 'bi bi-person-fill' },
    { name: 'Event', color: 'var(--color-red-400)', icon: 'bi bi-calendar-event' },
    { name: 'Gathering', color: 'var(--color-green-500)', icon: 'bi bi-people-fill' },
    { name: 'Organisation', color: 'var(--color-red-400)', icon: 'bi bi-flag-fill' },
    { name: 'Organisationship', color: 'var(--color-green-500)', icon: 'bi bi-person-fill' }
  ],

  dynamicLoadingTimeout: 500,

  // Helper functions for bounds validation and fallback
  validateBounds: function (bounds) {
    if (!bounds) return null;

    var west = parseFloat(bounds.west || bounds[0]);
    var south = parseFloat(bounds.south || bounds[1]);
    var east = parseFloat(bounds.east || bounds[2]);
    var north = parseFloat(bounds.north || bounds[3]);

    if (!isNaN(west) && !isNaN(south) && !isNaN(east) && !isNaN(north)) {
      return { west: west, south: south, east: east, north: north };
    }

    return null;
  },

  setDefaultView: function () {
    window.map.setCenter({ lat: 0, lng: 35 });
    window.map.setZoom(0);
  },

  fitValidBounds: function (bounds) {
    var validBounds = this.validateBounds(bounds);
    if (validBounds) {
      window.map.fitBounds(validBounds);
      return true;
    } else {
      this.setDefaultView();
      return false;
    }
  },

  fillScreen: function () {
    // In an embed, the iframe grows to fit its content, so filling it would feed back on itself: size to the screen instead
    if (window.self !== window.top) {
      document.getElementById('map-canvas').style.height = Math.round(window.screen.availHeight * 0.7) + 'px';
      return;
    }

    const mapContainer = document.getElementById('map-container');
    const mapContainerTop = mapContainer.getBoundingClientRect().top;
    const headerHeight = mapContainerTop;
    const remainingHeight = window.innerHeight - headerHeight;
    const minHeight = window.innerHeight * 0.5;
    const finalHeight = Math.max(remainingHeight, minHeight);
    document.getElementById('map-canvas').style.height = finalHeight + 'px';
  },

  // Initialize map with given configuration. The Maps libraries load on demand (see layouts/_dependencies.erb)
  initializeMap: async function (config) {
    try {
      await Promise.all([google.maps.importLibrary('maps'), google.maps.importLibrary('marker')]);
    } catch (error) {
      console.error('Error loading Google Maps:', error);
      $('#map-container').html('<div class="alert alert-warning"><p class="mb-0">Please enable cookies and refresh the page to view the map</p></div>');
      return;
    }

    window.mapTimer = null;

    if (config.fillScreen) {
      var self = this;
      // Set height on load and resize
      self.fillScreen();
      $(window).on('resize', function () { self.fillScreen(); });
    }

    // Advanced markers need a map ID
    window.map = new google.maps.Map(document.getElementById('map-canvas'), Object.assign({ mapId: config.mapId }, this.mapOptions));
    var bounds = new google.maps.LatLngBounds();

    // Initialize info window
    var infowindow = new google.maps.InfoWindow();
    window.mapInfoWindow = infowindow;

    // Create markers
    var markers = this.createMarkers(config.points, infowindow, bounds);

    // Create polygons
    var polygons = this.createPolygons(config.polygonPaths, bounds);

    // Setup clustering
    this.setupClustering(markers, infowindow);

    // Set map bounds/center
    this.setMapBounds(bounds, config);

    // Setup dynamic loading if enabled
    if (config.url) {
      this.setupDynamicLoading(config);
    }

    // Set map height after initialization if dynamic height is enabled
    if (config.fillScreen) {
      this.fillScreen();
    }

    return { map: window.map, markers: markers, polygons: polygons };
  },

  createMarkers: function (points, infowindow, bounds) {
    var markers = [];

    for (var i = 0; i < points.length; i++) {
      var point = points[i];
      var modelConfig = this.models.find(model => model.name == point.model_name);

      var pin = document.createElement('div');
      pin.className = 'map-marker';
      pin.style.setProperty('--map-marker-color', modelConfig.color);
      pin.innerHTML = '<i class="' + modelConfig.icon + '"></i>';

      var marker = new google.maps.marker.AdvancedMarkerElement({
        position: { lat: point.lat, lng: point.lng },
        content: pin,
        gmpClickable: true
      });
      marker.modelName = point.model_name;
      marker.pointId = point.id;
      marker.n = point.n;

      // Add click listener
      this.addMarkerClickListener(marker, infowindow);

      bounds.extend(marker.position);

      markers.push(marker);
    }

    return markers;
  },

  addMarkerClickListener: function (marker, infowindow) {
    var self = this;
    marker.addEventListener('gmp-click', function () {
      var timeout = self.dynamicLoadingTimeout;
      setTimeout(function () {
        clearTimeout(window.mapTimer);
      }, timeout);

      // Fade the marker while its details load
      marker.classList.add('map-loading');

      infowindow.close();

      $.get('/points/' + marker.modelName + '/' + marker.pointId)
        .done(function (data) {
          infowindow.setContent('<div class="infowindow">' + data + '</div>');
          infowindow.open({ map: window.map, anchor: marker });
        })
        .fail(function (xhr, status, error) {
          console.error('Error loading marker data:', error);
        })
        .always(function () {
          marker.classList.remove('map-loading');
        });
    });
  },

  createPolygons: function (polygonPaths, bounds) {
    var polygons = [];

    for (var i = 0; i < polygonPaths.length; i++) {
      var polygon = new google.maps.Polygon(Object.assign({}, this.polygonStyle, {
        map: window.map,
        paths: polygonPaths[i]
      }));

      // Extend bounds with polygon paths
      var paths = polygon.getPaths();
      for (var ii = 0; ii < paths.getLength(); ii++) {
        var path = paths.getAt(ii);
        for (var iii = 0; iii < path.getLength(); iii++) {
          bounds.extend(path.getAt(iii));
        }
      }

      polygons.push(polygon);
    }

    return polygons;
  },

  // A cluster is a .map-cluster circle (app.css) that turns from green to orange to red as it grows
  renderCluster: function (cluster) {
    var count = cluster.count;
    var circle = document.createElement('div');
    circle.className = 'map-cluster ' + (count < 10 ? 'map-cluster-sm' : count < 100 ? 'map-cluster-md' : 'map-cluster-lg');
    circle.textContent = count;

    return new google.maps.marker.AdvancedMarkerElement({
      position: cluster.position,
      content: circle,
      gmpClickable: true,
      zIndex: 1000 + count
    });
  },

  setupClustering: function (markers, infowindow) {
    var self = this;
    window.markerClusterer = new markerClusterer.MarkerClusterer({
      map: window.map,
      markers: markers,
      renderer: { render: function (cluster) { return self.renderCluster(cluster); } },
      // At the closest zoom, the points in a cluster share a place, so list them all rather than zooming
      onClusterClick: function (event, cluster) {
        if (window.map.getZoom() >= self.mapOptions.maxZoom) {
          self.handleClusterClick(cluster, infowindow);
        } else {
          window.map.setCenter(cluster.position);
          window.map.setZoom(window.map.getZoom() + 2);
        }
      }
    });
  },

  handleClusterClick: function (cluster, infowindow) {
    var markers = cluster.markers.slice();
    markers.sort(function (a, b) {
      return a.n - b.n;
    });

    infowindow.close();
    infowindow.setPosition(cluster.position);

    setTimeout(function () {
      clearTimeout(window.mapTimer);
    }, this.dynamicLoadingTimeout);

    // Fade the cluster while its details load
    var clusterMarker = cluster.marker;
    if (clusterMarker) {
      clusterMarker.classList.add('map-loading');
    }

    var content = '';
    var requests = markers.map(function (marker) {
      return $.get('/points/' + marker.modelName + '/' + marker.pointId)
        .done(function (data) {
          content += '<div class="mb-3">' + data + '</div>';
        })
        .fail(function (xhr, status, error) {
          console.error('Error loading marker data for ' + marker.modelName + '/' + marker.pointId + ':', error);
        });
    });

    $.when.apply($, requests).done(function () {
      infowindow.setContent('<div class="infowindow">' + (content.length > 0 ? content : '<em>Nothing to show</em>') + '</div>');
      infowindow.open({ map: window.map });
    }).fail(function () {
      console.error('Error loading cluster marker data');
    }).always(function () {
      if (clusterMarker) {
        clusterMarker.classList.remove('map-loading');
      }
    });
  },

  setMapBounds: function (bounds, config) {
    if (config.boundingBox) {
      console.log('using config.boundingBox');
      this.fitValidBounds(config.boundingBox);
    } else if (config.polygonPaths && config.polygonPaths.length > 0) {
      console.log('using config.polygonPaths');
      window.map.fitBounds(bounds);
    } else if (config.points && config.points.length > 0) {
      console.log('using config.points');
      window.map.fitBounds(bounds);
    } else {
      console.log('using default view');
      this.setDefaultView();
    }
  },

  setupDynamicLoading: function (config) {
    var self = this;
    var isFirstLoad = true;
    google.maps.event.addListenerOnce(window.map, 'idle', function () {
      window.map.addListener('bounds_changed', function () {
        var bounds = window.map.getBounds().toJSON();

        // Normalize bounds when crossing the antimeridian (date line)
        // If west > east, we're crossing the date line
        var west = bounds['west'];
        var east = bounds['east'];

        if (west > east) {
          // When crossing date line, convert east from negative to 0-360 range
          east += 360;
        }

        var q = {
          south: bounds['south'],
          west: west,
          north: bounds['north'],
          east: east,
        };

        // Parse URL to extract base path and existing parameters
        var url = config.url;
        var urlParts = url.split('?');
        var basePath = urlParts[0];
        var urlParams = {};

        if (urlParts.length > 1) {
          // Parse existing parameters from url
          urlParams = $.deparam(urlParts[1]);
        }

        var queryParams = $.deparam(window.location.search.substring(1));

        // Merge url parameters with dynamic request parameters
        var requestParams = jQuery.extend({}, urlParams, queryParams, q, { display: 'map' });
        var jsonUrl = basePath + '.json?' + $.param(requestParams);

        clearTimeout(window.mapTimer);
        var timeout = self.dynamicLoadingTimeout;
        window.mapTimer = setTimeout(function () {

          // Make JSON request to get new points
          $.ajax({
            url: jsonUrl,
            method: 'GET',
            dataType: 'json',
            success: function (data) {
              self.updateMapWithNewData(data, config, isFirstLoad);
              isFirstLoad = false;
            },
            error: function (xhr, status, error) {
              console.error('Failed to load map data:', error);
            }
          });
        }, timeout);
      });

      google.maps.event.trigger(window.map, 'bounds_changed');
    });
  },

  updateMapWithNewData: function (data, config, isFirstLoad) {
    // Create new markers from JSON data
    var bounds = new google.maps.LatLngBounds();
    var markers = [];
    if (data.points && data.points.length > 0) {
      markers = this.createMarkers(data.points, window.mapInfoWindow, bounds);
    }

    // Swap the clusterer's markers for the new ones
    window.markerClusterer.clearMarkers(true);
    window.markerClusterer.addMarkers(markers);

    // Update points warning
    if (data.pointsCount > (config.pointsLimit || 1000)) {
      $('#points-warning').show();
    } else {
      $('#points-warning').hide();
    }

    // Fit map to new points only on first load and if no specific bounds are configured
    if (isFirstLoad && markers.length > 0 && !config.boundingBox && (!config.polygonPaths || config.polygonPaths.length === 0)) {
      window.map.fitBounds(bounds);
    }
  }
};
