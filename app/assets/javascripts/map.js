// Map functionality
window.MapUtils = {
  // Configuration settings
  mapOptions: {
    mapTypeId: google.maps.MapTypeId.ROADMAP,
    mapTypeControl: false,
    scaleControl: true,
    streetViewControl: false,
    fullscreenControl: false,
    maxZoom: 16,
    minZoom: 1,
    gestureHandling: 'cooperative'
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

  dynamicLoadingTimeout: 750,

  defaultCenter: { lat: 35, lng: 0 },
  defaultZoom: 0,

  clusterConfig: {
    zoomOnClick: false
  },

  disabledMapOptions: {
    draggable: false,
    zoomControl: false,
    scrollwheel: false,
    disableDoubleClickZoom: true
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
    window.map.setCenter(new google.maps.LatLng(this.defaultCenter.lat, this.defaultCenter.lng));
    window.map.setZoom(this.defaultZoom);
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

  // Initialize map with given configuration
  initializeMap: function (config) {
    if (typeof google === 'undefined') {
      $('#map-container').html('<div class="alert alert-warning"><p class="mb-0">Please enable cookies and refresh the page to view the map</p></div>');
      return;
    }

    var params = this.getContainerParams();
    window.mapTimer = null;

    var mapOptions = Object.assign({}, this.mapOptions, {
      minZoom: config.minZoom || this.mapOptions.minZoom
    });

    window.map = new google.maps.Map(document.getElementById("map-canvas"), mapOptions);
    var bounds = new google.maps.LatLngBounds();

    // Handle bounding box if provided
    if (params['bounding_box']) {
      this.drawBoundingBox(params['bounding_box']);
    }

    // Initialize info window
    var infowindow = new google.maps.InfoWindow();

    // Create markers
    var markers = this.createMarkers(config.points, infowindow, bounds, config.infoWindow, config.polygonables);

    // Create polygons
    var polygons = this.createPolygons(config.polygonPaths, bounds);

    // Setup clustering
    this.setupClustering(markers, infowindow, config.infoWindow);

    // Set map bounds/center
    this.setMapBounds(bounds, config);

    // Setup dynamic loading if enabled
    if (config.dynamic) {
      this.setupDynamicLoading(params, config);
    }

    return { map: window.map, markers: markers, polygons: polygons };
  },

  getContainerParams: function () {
    var query;
    var pagelet = $('#map-container').closest('[data-pagelet-url]');
    var turboFrame = $('#map-container').closest('turbo-frame');

    if (pagelet.length > 0) {
      query = pagelet.attr('data-pagelet-url').split('?')[1];
    } else if (turboFrame.length > 0 && turboFrame.attr('src')) {
      query = turboFrame.attr('src').split('?')[1];
    } else {
      query = window.location.search;
    }
    return Object.fromEntries(new URLSearchParams(query || ''));
  },

  getContainer: function () {
    var pagelet = $('#map-container').closest('[data-pagelet-url]');
    var turboFrame = $('#map-container').closest('turbo-frame');

    if (pagelet.length > 0) {
      return { type: 'pagelet', element: pagelet };
    } else if (turboFrame.length > 0) {
      return { type: 'turbo-frame', element: turboFrame };
    } else {
      return { type: 'none', element: null };
    }
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

    new google.maps.Polygon(Object.assign({}, this.boundingBoxStyle, {
      paths: boundingBoxPaths,
      map: window.map
    }));
  },

  createMarkers: function (points, infowindow, bounds, infoWindowEnabled, polygonables) {
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
      this.addMarkerClickListener(marker, infowindow, infoWindowEnabled);

      // Extend bounds if not using polygonables
      if (!polygonables) {
        console.log('pushed ' + marker.getPosition().toJSON() + ' to bounds');
        bounds.extend(marker.getPosition());
      }

      markers.push(marker);
    }

    return markers;
  },

  addMarkerClickListener: function (marker, infowindow, infoWindowEnabled) {
    var self = this;
    google.maps.event.addListener(marker, 'click', function () {
      if (self.shouldShowInfoWindow(marker.model_name, infoWindowEnabled)) {
        infowindow.setContent('<i class="bi bi-spin bi-arrow-repeat"></i>');
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

  shouldShowInfoWindow: function (modelName, infoWindowEnabled) {
    return this.infoWindowModels.includes(modelName) || infoWindowEnabled;
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

  setupClustering: function (markers, infowindow, infoWindowEnabled) {
    var markerClusterer = new MarkerClusterer(window.map, markers, Object.assign({}, this.clusterConfig, {
      styles: this.clusterStyles
    }));

    var self = this;
    google.maps.event.addListener(markerClusterer, 'clusterclick', function (cluster) {
      if (window.map.getZoom() === window.map.maxZoom) {
        self.handleClusterClick(cluster, infowindow, infoWindowEnabled);
      } else {
        window.map.setCenter(cluster.getCenter());
        window.map.setZoom(window.map.getZoom() + 2);
      }
    });
  },

  handleClusterClick: function (cluster, infowindow, infoWindowEnabled) {
    var markers = cluster.getMarkers();
    markers.sort(function (a, b) {
      return a.n - b.n;
    });

    infowindow.setContent('<i class="bi bi-spin bi-arrow-repeat"></i>');
    infowindow.setPosition(cluster.getCenter());
    infowindow.open(window.map);

    setTimeout(function () {
      clearTimeout(window.mapTimer);
    }, this.dynamicLoadingTimeout);

    var content = '';
    var self = this;
    var requests = markers.map(function (marker) {
      return $.get('/point/' + marker.model_name + '/' + marker.id, function (data) {
        if (self.shouldShowInfoWindow(marker.model_name, infoWindowEnabled)) {
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
    } else if (!config.points || config.points.length === 0 || config.pointsExceedLimit) {
      var params = this.getContainerParams();
      if (params['bounding_box']) {
        console.log("using params['bounding_box']");
        this.fitValidBounds(params['bounding_box'], 'Invalid bounding box');
      } else {
        console.log('using default view');
        this.setDefaultView();
      }
    } else {
      console.log('using map bounds');
      window.map.fitBounds(bounds);
    }
  },

  setupDynamicLoading: function (params, config) {
    var self = this;
    google.maps.event.addListenerOnce(window.map, 'idle', function () {
      window.map.addListener('bounds_changed', function () {
        var q;
        var bounds = window.map.getBounds().toJSON();
        var center = window.map.getCenter().toJSON();
        var zoom = window.map.getZoom();
        if (config.triggerBoundsChanged) {
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

        jQuery.extend(params, q);
        var container = self.getContainer();
        var stem = config.stem || '/map';
        var newUrl = stem + '/?' + $.param(params);

        if (container.type === 'pagelet') {
          container.element.attr('data-pagelet-url', newUrl);
        }

        clearTimeout(window.mapTimer);
        var timeout = self.dynamicLoadingTimeout;
        window.mapTimer = setTimeout(function () {
          window.map.setOptions(self.disabledMapOptions);

          if (container.type === 'pagelet') {
            container.element.css('opacity', '0.3');
            container.element.load(newUrl, function () {
              container.element.css('opacity', '1');
            });
          } else if (container.type === 'turbo-frame') {
            container.element.attr('src', newUrl);
          }
        }, timeout);
      });

      if (config.triggerBoundsChanged) {
        google.maps.event.trigger(window.map, 'bounds_changed');
      }

      if (config.pointsExceedLimit) {
        $('#points-warning').show();
      }
    });
  }
};
