// Map functionality
window.DandelionMap = {
  // Constants
  POINTS_LIMIT: 500,
  // Configuration settings - lazy loaded to avoid referencing google before it's available
  get mapOptions () {
    return {
      mapTypeId: google.maps.MapTypeId.ROADMAP,
      mapTypeControl: false,
      scaleControl: true,
      streetViewControl: false,
      fullscreenControl: false,
      maxZoom: 16,
      minZoom: 1,
      gestureHandling: 'greedy',
      clickableIcons: false,
      scrollwheel: true,
      draggable: true,
      disableDoubleClickZoom: false
    };
  },

  // Helper function to generate cluster styles
  generateClusterStyle: function (color, textSize = 16) {
    return {
      textColor: 'white',
      textSize: textSize,
      fontFamily: 'Plus Jakarta Sans',
      url: `/images/cluster-${color}.png`,
      height: 50,
      width: 50
    };
  },

  // Generate cluster styles using the helper function
  get clusterStyles () {
    return [
      this.generateClusterStyle('green'),
      this.generateClusterStyle('yellow'),
      this.generateClusterStyle('red', 14)
    ];
  },

  polygonStyle: {
    strokeColor: '#FBAE3B',
    strokeOpacity: 0.8,
    strokeWeight: 2,
    fillColor: '#FBAE3B',
    fillOpacity: 0.35
  },

  boundingBoxStyle: {
    strokeColor: '#000000',
    strokeOpacity: 0.1,
    strokeWeight: 2,
    fillColor: '#000000',
    fillOpacity: 0.05
  },

  infoWindowModels: ['Organisation', 'Gathering', 'Event'],

  // Model configurations for map markers
  models: [
    { name: 'Organisation', color: '#FF5241', icon: 'bi bi-flag-fill' },
    { name: 'Gathering', color: '#00B963', icon: 'bi bi-people-fill' },
    { name: 'Event', color: '#FF5241', icon: 'bi bi-calendar-event' },
    { name: 'Account', color: '#00B963', icon: 'bi bi-person-fill' },
    { name: 'ActivityApplication', color: '#00B963', icon: 'bi bi-person-fill' },
    { name: 'Organisationship', color: '#00B963', icon: 'bi bi-person-fill' }
  ],

  dynamicLoadingTimeout: 500,

  clusterConfig: {
    zoomOnClick: false
  },

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
    window.map.setCenter(new google.maps.LatLng(0, 35));
    window.map.setZoom(0);
  },

  fitValidBounds: function (bounds, errorMessage) {
    var validBounds = this.validateBounds(bounds);
    if (validBounds) {
      window.map.fitBounds(validBounds);
      return true;
    } else {
      if (errorMessage) {
        console.warn(errorMessage, bounds);
      }
      this.setDefaultView();
      return false;
    }
  },

  fillScreen: function () {
    const mapContainer = document.getElementById('map-container');
    const mapContainerTop = mapContainer.getBoundingClientRect().top;
    const headerHeight = mapContainerTop;
    const remainingHeight = window.innerHeight - headerHeight;
    const minHeight = window.innerHeight * 0.5;
    const finalHeight = Math.max(remainingHeight, minHeight);
    document.getElementById('map-canvas').style.height = finalHeight + 'px';

    // Trigger map resize if map exists
    if (window.map) {
      google.maps.event.trigger(window.map, 'resize');
    }
  },

  // Initialize map with given configuration
  initializeMap: function (config) {
    if (typeof google === 'undefined') {
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

    var mapOptions = Object.assign({}, this.mapOptions, {
      minZoom: config.minZoom || this.mapOptions.minZoom
    });

    window.map = new google.maps.Map(document.getElementById("map-canvas"), mapOptions);
    var bounds = new google.maps.LatLngBounds();

    // Handle bounding box if provided
    var boundingBoxPolygon = null;
    if (config.boundingBox) {
      boundingBoxPolygon = this.drawBoundingBox(config.boundingBox);
    }

    // Initialize info window
    var infowindow = new google.maps.InfoWindow();

    // Create markers
    var markers = this.createMarkers(config.points, infowindow, bounds, config.enableInfoWindow, config.polygonables);

    // Create polygons
    var polygons = this.createPolygons(config.polygonPaths, bounds);

    // Setup clustering
    this.setupClustering(markers, infowindow, config.enableInfoWindow);

    // Store references globally for dynamic updates
    window.mapInfoWindow = infowindow;
    window.mapPolygons = polygons;
    window.mapBoundingBoxPolygon = boundingBoxPolygon;

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

  drawBoundingBox: function (boundingBox) {
    var west = parseFloat(boundingBox[0]);
    var south = parseFloat(boundingBox[1]);
    var east = parseFloat(boundingBox[2]);
    var north = parseFloat(boundingBox[3]);

    var boundingBoxPaths = [
      { lat: south, lng: west },
      { lat: north, lng: west },
      { lat: north, lng: east },
      { lat: south, lng: east }
    ];

    var boundingBoxPolygon = new google.maps.Polygon(Object.assign({}, this.boundingBoxStyle, {
      paths: boundingBoxPaths,
      map: window.map
    }));

    return boundingBoxPolygon;
  },

  createMarkers: function (points, infowindow, bounds, enableInfoWindow, polygonables) {
    var markers = [];

    for (var i = 0; i < points.length; i++) {
      var point = points[i];
      var modelConfig = this.models.find(model => model.name == point.model_name);

      var marker = new mapIcons.Marker({
        model_name: point.model_name,
        id: point.id,
        n: point.n,
        position: new google.maps.LatLng(point.lat, point.lng),
        icon: {
          path: mapIcons.shapes.MAP_PIN,
          fillColor: modelConfig.color,
          fillOpacity: 1,
          strokeColor: '',
          strokeWeight: 0
        },
        map_icon_label: '<span class="' + modelConfig.icon + '"></span>'
      });

      // Add click listener
      this.addMarkerClickListener(marker, infowindow, enableInfoWindow);

      // Extend bounds if not using polygonables
      if (!polygonables) {
        console.log('pushed ' + marker.getPosition().toJSON() + ' to bounds');
        bounds.extend(marker.getPosition());
      }

      markers.push(marker);
    }

    return markers;
  },

  addMarkerClickListener: function (marker, infowindow, enableInfoWindow) {
    var self = this;
    google.maps.event.addListener(marker, 'click', function () {
      if (self.shouldShowInfoWindow(marker.model_name, enableInfoWindow)) {
        infowindow.setContent('<i class="bi bi-spin bi-slash-lg"></i>');
        infowindow.open(window.map, marker);
        var timeout = self.dynamicLoadingTimeout;
        setTimeout(function () {
          clearTimeout(window.mapTimer);
        }, timeout);

        $.get('/point/' + marker.model_name + '/' + marker.id, function (data) {
          infowindow.setContent('<div class="infowindow">' + data + '</div>');
        });
      }
    });
  },

  shouldShowInfoWindow: function (modelName, enableInfoWindow) {
    return this.infoWindowModels.includes(modelName) || enableInfoWindow;
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

  setupClustering: function (markers, infowindow, enableInfoWindow) {
    var markerClusterer = new MarkerClusterer(window.map, markers, Object.assign({}, this.clusterConfig, {
      styles: this.clusterStyles
    }));

    // Store reference globally for dynamic updates
    window.markerClusterer = markerClusterer;

    var self = this;
    google.maps.event.addListener(markerClusterer, 'clusterclick', function (cluster) {
      if (window.map.getZoom() === window.map.maxZoom) {
        self.handleClusterClick(cluster, infowindow, enableInfoWindow);
      } else {
        window.map.setCenter(cluster.getCenter());
        window.map.setZoom(window.map.getZoom() + 2);
      }
    });
  },

  handleClusterClick: function (cluster, infowindow, enableInfoWindow) {
    var markers = cluster.getMarkers();
    markers.sort(function (a, b) {
      return a.n - b.n;
    });

    infowindow.setContent('<i class="bi bi-spin bi-slash-lg"></i>');
    infowindow.setPosition(cluster.getCenter());
    infowindow.open(window.map);

    setTimeout(function () {
      clearTimeout(window.mapTimer);
    }, this.dynamicLoadingTimeout);

    var content = '';
    var self = this;
    var requests = markers.map(function (marker) {
      return $.get('/point/' + marker.model_name + '/' + marker.id, function (data) {
        if (self.shouldShowInfoWindow(marker.model_name, enableInfoWindow)) {
          content += '<div class="mb-3">' + data + '</div>';
        }
      });
    });

    $.when.apply($, requests).done(function () {
      infowindow.setContent('<div class="infowindow">' + (content.length > 0 ? content : '<em>Nothing to show</em>') + '</div>');
    });
  },

  setMapBounds: function (bounds, config) {
    if (config.centre) {
      console.log('using config.centre');
      window.map.setCenter(new google.maps.LatLng(config.centre.lat, config.centre.lng));
      window.map.setZoom(config.zoom);
    } else if (config.bounds) {
      console.log('using config.bounds');
      this.fitValidBounds(config.bounds, 'Invalid bounds');
    } else if (config.polygonables) {
      console.log('using config.polygonables');
      window.map.fitBounds(bounds);
    } else if (!config.points || config.points.length === 0 || (config.points && config.points.length > this.POINTS_LIMIT)) {
      if (config.boundingBox) {
        console.log("using config.boundingBox");
        this.fitValidBounds(config.boundingBox, 'Invalid bounding box');
      } else {
        console.log('using default view');
        this.setDefaultView();
      }
    } else {
      console.log('using map bounds');
      window.map.fitBounds(bounds);
    }
  },

  setupDynamicLoading: function (config) {
    var self = this;
    google.maps.event.addListenerOnce(window.map, 'idle', function () {
      window.map.addListener('bounds_changed', function () {
        var q;
        var bounds = window.map.getBounds().toJSON();
        var center = window.map.getCenter().toJSON();
        var zoom = window.map.getZoom();
        if (config.url) {
          q = {
            south: bounds['south'],
            west: bounds['west'],
            north: bounds['north'],
            east: bounds['east'],
          };
        } else {
          q = {
            south: bounds['south'],
            west: bounds['west'],
            north: bounds['north'],
            east: bounds['east'],
            lat: center['lat'],
            lng: center['lng'],
            zoom: zoom
          };
        }

        // Parse URL to extract base path and existing parameters
        var url = config.url;
        var urlParts = url.split('?');
        var basePath = urlParts[0];
        var urlParams = {};

        if (urlParts.length > 1) {
          // Parse existing parameters from url
          urlParams = $.deparam(urlParts[1]);
        }

        // Merge url parameters with dynamic request parameters
        var requestParams = jQuery.extend({}, urlParams, q, { display: 'map' });
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
              self.updateMapWithNewData(data, config);
              window.map.setOptions(self.mapOptions);
            },
            error: function (xhr, status, error) {
              console.error('Failed to load map data:', error);
              window.map.setOptions(self.mapOptions);
            }
          });
        }, timeout);
      });

      if (config.url) {
        google.maps.event.trigger(window.map, 'bounds_changed');
      }

      if (config.points && config.points.length > this.POINTS_LIMIT) {
        $('#points-warning').show();
      }
    });
  },

  updateMapWithNewData: function (data, config) {
    var self = this;

    // Clear existing markers and clusters
    if (window.markerClusterer) {
      window.markerClusterer.clearMarkers();
    }

    // Clear existing polygons
    if (window.mapPolygons) {
      window.mapPolygons.forEach(function (polygon) {
        polygon.setMap(null);
      });
    }

    // Clear existing bounding box
    if (window.mapBoundingBoxPolygon) {
      window.mapBoundingBoxPolygon.setMap(null);
    }

    // Create new bounds
    var bounds = new google.maps.LatLngBounds();

    // Initialize info window if it doesn't exist
    if (!window.mapInfoWindow) {
      window.mapInfoWindow = new google.maps.InfoWindow();
    }

    // Create new markers from JSON data
    var markers = [];
    if (data.points && data.points.length > 0) {
      markers = this.createMarkers(data.points, window.mapInfoWindow, bounds, data.enableInfoWindow, data.polygonables);
    }

    // Create new polygons if provided
    var polygons = [];
    if (data.polygonPaths && data.polygonPaths.length > 0) {
      polygons = this.createPolygons(data.polygonPaths, bounds);
    }
    window.mapPolygons = polygons;

    // Redraw bounding box if it exists in config
    if (config.boundingBox) {
      window.mapBoundingBoxPolygon = this.drawBoundingBox(config.boundingBox);
    }

    // Setup new clustering
    if (markers.length > 0) {
      this.setupClustering(markers, window.mapInfoWindow, data.enableInfoWindow);
    }

    // Update points warning
    if (data.pointsCount > this.POINTS_LIMIT) {
      $('#points-warning').show();
    } else {
      $('#points-warning').hide();
    }

    // Store reference to marker clusterer
    window.markerClusterer = window.markerClusterer;
  }
};
