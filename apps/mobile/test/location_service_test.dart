import 'package:flutter_test/flutter_test.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:savorseek/features/location/location_service.dart';

void main() {
  test(
    'a timeout does not permanently poison a later location attempt',
    () async {
      final service = AmapLocationService(
        timeout: const Duration(milliseconds: 1),
      );

      await expectLater(
        service.getCurrentLocation(),
        throwsA(
          isA<LocationException>().having(
            (error) => error.failure,
            'failure',
            LocationFailure.timeout,
          ),
        ),
      );

      service.update(const AMapLocation(latLng: LatLng(31.2304, 121.4737)));

      await expectLater(
        service.getCurrentLocation(),
        completion(
          isA<DeviceLocation>()
              .having((location) => location.latitude, 'latitude', 31.2304)
              .having(
                (location) => location.longitude,
                'longitude',
                closeTo(121.4737, 0.000001),
              ),
        ),
      );
    },
  );
}
