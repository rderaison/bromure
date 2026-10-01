"""Parse the trusted baseline encoder fixture into the pinned VirGL descriptor."""
import ctypes as C
import re
import struct

class SPS(C.Structure):
    _fields_ = [(n, C.c_uint8) for n in ('level_idc', 'chroma_format_idc', 'separate_colour_plane_flag',
        'bit_depth_luma_minus8', 'bit_depth_chroma_minus8', 'seq_scaling_matrix_present_flag')]
    _fields_ += [('ScalingList4x4', (C.c_uint8 * 16) * 6), ('ScalingList8x8', (C.c_uint8 * 64) * 6)]
    _fields_ += [(n, C.c_uint8) for n in ('log2_max_frame_num_minus4', 'pic_order_cnt_type',
        'log2_max_pic_order_cnt_lsb_minus4', 'delta_pic_order_always_zero_flag')]
    _fields_ += [('offset_for_non_ref_pic', C.c_int32), ('offset_for_top_to_bottom_field', C.c_int32),
        ('offset_for_ref_frame', C.c_int32 * 256)]
    _fields_ += [(n, C.c_uint8) for n in ('num_ref_frames_in_pic_order_cnt_cycle', 'max_num_ref_frames',
        'frame_mbs_only_flag', 'mb_adaptive_frame_field_flag', 'direct_8x8_inference_flag', 'MinLumaBiPredSize8x8')]
    _fields_ += [('reserved', C.c_uint8 * 2)]
class PPS(C.Structure):
    _fields_ = [('sps', SPS)]
    _fields_ += [(n, C.c_uint8) for n in ('entropy_coding_mode_flag', 'bottom_field_pic_order_in_frame_present_flag',
        'num_slice_groups_minus1', 'slice_group_map_type', 'slice_group_change_rate_minus1',
        'num_ref_idx_l0_default_active_minus1', 'num_ref_idx_l1_default_active_minus1', 'weighted_pred_flag', 'weighted_bipred_idc')]
    _fields_ += [(n, C.c_int8) for n in ('pic_init_qp_minus26', 'pic_init_qs_minus26', 'chroma_qp_index_offset')]
    _fields_ += [(n, C.c_uint8) for n in ('deblocking_filter_control_present_flag', 'constrained_intra_pred_flag',
        'redundant_pic_cnt_present_flag', 'transform_8x8_mode_flag')]
    _fields_ += [('ScalingList4x4', (C.c_uint8 * 16) * 6), ('ScalingList8x8', (C.c_uint8 * 64) * 6),
        ('second_chroma_qp_index_offset', C.c_int8), ('reserved', C.c_uint8 * 3)]
class Bits:
    def __init__(self, nal):
        self.data = nal[1:].replace(b'\x00\x00\x03', b'\x00\x00'); self.pos = 0
    def get(self, count=1):
        assert self.pos + count <= len(self.data) * 8
        value = 0
        for _ in range(count):
            value = (value << 1) | ((self.data[self.pos // 8] >> (7 - self.pos % 8)) & 1); self.pos += 1
        return value
    def ue(self):
        count = 0
        while not self.get():
            count += 1; assert count < 32
        return (1 << count) - 1 + self.get(count)
    def se(self):
        value = self.ue(); return (value + 1) // 2 if value & 1 else -value // 2

def descriptor_and_slices(fixture):
    nals = [n for n in re.split(b'\x00\x00(?:\x00)?\x01', fixture) if n]
    sps_nal = next(n for n in nals if n[0] & 31 == 7); pps_nal = next(n for n in nals if n[0] & 31 == 8)
    b = Bits(sps_nal); profile = b.get(8); b.get(8); level = b.get(8); b.ue()
    assert profile == 66, profile
    s = SPS(); s.level_idc = level; s.chroma_format_idc = 1
    s.log2_max_frame_num_minus4 = b.ue(); s.pic_order_cnt_type = b.ue()
    if s.pic_order_cnt_type == 0: s.log2_max_pic_order_cnt_lsb_minus4 = b.ue()
    elif s.pic_order_cnt_type == 1:
        s.delta_pic_order_always_zero_flag = b.get(); s.offset_for_non_ref_pic = b.se(); s.offset_for_top_to_bottom_field = b.se()
        s.num_ref_frames_in_pic_order_cnt_cycle = b.ue()
        for i in range(s.num_ref_frames_in_pic_order_cnt_cycle): s.offset_for_ref_frame[i] = b.se()
    s.max_num_ref_frames = b.ue(); b.get(); mbw = b.ue() + 1; mbh = b.ue() + 1
    s.frame_mbs_only_flag = b.get(); assert s.frame_mbs_only_flag
    s.direct_8x8_inference_flag = b.get()
    assert 0 < mbw <= 256 and 0 < mbh <= 256
    p = PPS(); p.sps = s; b = Bits(pps_nal); pps_id = b.ue(); b.ue()
    p.entropy_coding_mode_flag = b.get(); p.bottom_field_pic_order_in_frame_present_flag = b.get()
    p.num_slice_groups_minus1 = b.ue(); assert p.num_slice_groups_minus1 == 0
    p.num_ref_idx_l0_default_active_minus1 = b.ue(); p.num_ref_idx_l1_default_active_minus1 = b.ue()
    p.weighted_pred_flag = b.get(); p.weighted_bipred_idc = b.get(2)
    p.pic_init_qp_minus26 = b.se(); p.pic_init_qs_minus26 = b.se(); p.chroma_qp_index_offset = b.se()
    p.deblocking_filter_control_present_flag = b.get(); p.constrained_intra_pred_flag = b.get(); p.redundant_pic_cnt_present_flag = b.get()
    p.second_chroma_qp_index_offset = p.chroma_qp_index_offset
    # Descriptor base is 264 bytes; PPS follows immediately with native 4-byte alignment.
    descriptor = struct.pack('<HBB', 9, 1, 0) + bytes(260) + bytes(p)
    descriptor += bytes(5132 - len(descriptor))
    slices = b''.join(b'\x00\x00\x00\x01' + n for n in nals if n[0] & 31 not in (7, 8))
    return descriptor, slices, (mbw * 16, mbh * 16)
