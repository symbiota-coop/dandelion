/**
 * @license Copyright (c) 2003-2023, CKSource Holding sp. z o.o. All rights reserved.
 * For licensing, see LICENSE.md or https://ckeditor.com/legal/ckeditor-oss-license
 */

// Dandelion's CKEditor 5 build, on CKEditor 37.1.0: the last version without the Powered by CKEditor badge, which
// 38 added for open source use. Run `rake ckeditor:build` to write app/assets/javascripts/ext/ckeditor.js

import { ClassicEditor as ClassicEditorBase } from '@ckeditor/ckeditor5-editor-classic'

import { Alignment } from '@ckeditor/ckeditor5-alignment'
import { Autoformat } from '@ckeditor/ckeditor5-autoformat'
import { Bold, Italic } from '@ckeditor/ckeditor5-basic-styles'
import { BlockQuote } from '@ckeditor/ckeditor5-block-quote'
import { CodeBlock } from '@ckeditor/ckeditor5-code-block'
import { Essentials } from '@ckeditor/ckeditor5-essentials'
import { FontBackgroundColor, FontColor } from '@ckeditor/ckeditor5-font'
import { Heading } from '@ckeditor/ckeditor5-heading'
import { HorizontalLine } from '@ckeditor/ckeditor5-horizontal-line'
import { HtmlEmbed } from '@ckeditor/ckeditor5-html-embed'
import { ImageCaption, ImageResize, ImageStyle, ImageToolbar, ImageUpload } from '@ckeditor/ckeditor5-image'
// Not exported from the package root in 37
import ImageBlock from '@ckeditor/ckeditor5-image/src/imageblock'
import { Indent } from '@ckeditor/ckeditor5-indent'
import { Link, LinkImage } from '@ckeditor/ckeditor5-link'
import { List } from '@ckeditor/ckeditor5-list'
import { MediaEmbed } from '@ckeditor/ckeditor5-media-embed'
import { Paragraph } from '@ckeditor/ckeditor5-paragraph'
import { PasteFromOffice } from '@ckeditor/ckeditor5-paste-from-office'
import { Table, TableToolbar } from '@ckeditor/ckeditor5-table'
import { TextTransformation } from '@ckeditor/ckeditor5-typing'
import { SimpleUploadAdapter } from '@ckeditor/ckeditor5-upload'

export default class ClassicEditor extends ClassicEditorBase { }

// Plugins to include in the build.
ClassicEditor.builtinPlugins = [
	Alignment,
	Autoformat,
	BlockQuote,
	Bold,
	CodeBlock,
	Essentials,
	FontBackgroundColor,
	FontColor,
	Heading,
	HorizontalLine,
	HtmlEmbed,
	// Block images only (figure.image), as in CKEditor 27, so content keeps the same shape
	ImageBlock,
	ImageCaption,
	ImageResize,
	ImageStyle,
	ImageToolbar,
	ImageUpload,
	Indent,
	Italic,
	Link,
	LinkImage,
	List,
	MediaEmbed,
	Paragraph,
	PasteFromOffice,
	SimpleUploadAdapter,
	Table,
	TableToolbar,
	TextTransformation
]

// Editor configuration.
ClassicEditor.defaultConfig = {
	toolbar: {
		items: [
			'heading',
			'|',
			'bold',
			'italic',
			'fontColor',
			'fontBackgroundColor',
			'link',
			'bulletedList',
			'numberedList',
			'blockQuote',
			'horizontalLine',
			'insertTable',
			'alignment',
			'codeBlock',
			'|',
			'outdent',
			'indent',
			'|',
			'uploadImage',
			'mediaEmbed',
			'htmlEmbed',
			'|',
			'undo',
			'redo'
		]
	},
	heading: {
		options: [
			{ model: 'paragraph', title: 'Paragraph', class: 'ck-heading_paragraph' },
			{ model: 'paragraphLead', view: { name: 'p', classes: 'lead' }, title: 'Paragraph (lead)', class: 'ck-heading_paragraph_lead', converterPriority: 'high' },
			{ model: 'paragraphSmall', view: { name: 'p', classes: 'small' }, title: 'Paragraph (small)', class: 'ck-heading_paragraph_small', converterPriority: 'high' },
			{ model: 'paragraphAction', view: { name: 'p', classes: 'action' }, title: 'Paragraph (action)', class: 'ck-heading_paragraph_action', converterPriority: 'high' },
			{ model: 'heading1', view: 'h1', title: 'Heading 1', class: 'ck-heading_heading1' },
			{ model: 'heading2', view: 'h2', title: 'Heading 2', class: 'ck-heading_heading2' },
			{ model: 'heading3', view: 'h3', title: 'Heading 3', class: 'ck-heading_heading3' },
			{ model: 'heading4', view: 'h4', title: 'Heading 4', class: 'ck-heading_heading4' }
		]
	},
	image: {
		styles: {
			options: ['alignLeft', 'alignCenter', 'alignRight']
		},
		toolbar: ['imageStyle:alignLeft', 'imageStyle:alignCenter', 'imageStyle:alignRight', 'linkImage']
	},
	table: {
		contentToolbar: [
			'tableColumn',
			'tableRow',
			'mergeTableCells'
		]
	},
	simpleUpload: {
		uploadUrl: '/upload'
	},
	link: {
		decorators: {
			openInNewTab: {
				mode: 'manual',
				label: 'Open in a new tab',
				attributes: {
					target: '_blank'
				}
			}
		}
	},
	// This value must be kept in sync with the language defined in webpack.config.js.
	language: 'en'
}
