/**
 * @license Copyright (c) 2003-2023, CKSource Holding sp. z o.o. All rights reserved.
 * For licensing, see LICENSE.md or https://ckeditor.com/legal/ckeditor-oss-license
 */

// Based on the webpack config of CKEditor 37.1.0's classic build (packages/ckeditor5-build-classic), for a JavaScript
// source and English only

'use strict';

/* eslint-env node */

const path = require( 'path' );
const webpack = require( 'webpack' );
const { bundler, loaders } = require( '@ckeditor/ckeditor5-dev-utils' );
const { CKEditorTranslationsPlugin } = require( '@ckeditor/ckeditor5-dev-translations' );
const TerserPlugin = require( 'terser-webpack-plugin' );

module.exports = {
	performance: { hints: false },

	entry: path.resolve( __dirname, 'src', 'ckeditor.js' ),

	output: {
		// The name under which the editor will be exported.
		library: 'ClassicEditor',

		path: path.resolve( __dirname, 'build' ),
		filename: 'ckeditor.js',
		libraryTarget: 'umd',
		libraryExport: 'default'
	},

	optimization: {
		minimizer: [
			new TerserPlugin( {
				terserOptions: {
					output: {
						// Preserve CKEditor 5 license comments.
						comments: /^!/
					}
				},
				extractComments: false
			} )
		]
	},

	plugins: [
		new CKEditorTranslationsPlugin( {
			// UI language. When changing it, also change it in the editor's configuration (src/ckeditor.js)
			language: 'en'
		} ),
		new webpack.BannerPlugin( {
			banner: bundler.getLicenseBanner(),
			raw: true
		} )
	],

	module: {
		rules: [
			loaders.getIconsLoader( { matchExtensionOnly: true } ),
			loaders.getStylesLoader( {
				themePath: require.resolve( '@ckeditor/ckeditor5-theme-lark' ),
				minify: true
			} )
		]
	}
};
