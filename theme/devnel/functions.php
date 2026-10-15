<?php
/**
 * Theme bootstrap: loads every file in inc/, one concern per file.
 *
 * @package devnel
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

$devnel_inc_files = glob( get_template_directory() . '/inc/*.php' );

if ( is_array( $devnel_inc_files ) ) {
	sort( $devnel_inc_files );
	foreach ( $devnel_inc_files as $devnel_inc_file ) {
		require_once $devnel_inc_file;
	}
}

unset( $devnel_inc_files, $devnel_inc_file );
