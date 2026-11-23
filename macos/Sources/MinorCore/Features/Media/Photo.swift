import Foundation
import ImageIO

/// Capture date, size and EXIF orientation of a photo (HEIC included), read from the header only.
struct PhotoInfo: Sendable, Equatable {
	var taken: Date?
	/// As stored, before rotation.
	var width: Int?
	var height: Int?
	/// EXIF 1…8.
	var orientation: Int?

	static func read(_ path: String) -> PhotoInfo? {
		guard let src = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
		      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
		else { return nil }
		var info = PhotoInfo()
		info.width = p[kCGImagePropertyPixelWidth] as? Int
		info.height = p[kCGImagePropertyPixelHeight] as? Int
		if let o = p[kCGImagePropertyOrientation] as? Int, (1...8).contains(o) { info.orientation = o }
		let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
		let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
		let stamp = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
		if let stamp, let d = exifDate.date(from: stamp), Calendar.current.component(.year, from: d) > 1900 { info.taken = d }
		return info
	}

	/// EXIF has no time zone; the camera clock is taken as local time.
	private static let exifDate: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyy:MM:dd HH:mm:ss"
		return f
	}()
}
